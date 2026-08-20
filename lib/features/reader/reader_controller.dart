import 'package:flutter/foundation.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../core/models/reader_settings.dart';
import '../../core/models/text_block.dart';
import '../../core/services/language_detector.dart';
import '../../core/services/pdf_block_extractor.dart';
import '../../core/services/translation_service.dart';

/// État de traduction d'un bloc.
enum BlockState { pending, translating, done, error }

class BlockProgress {
  const BlockProgress({
    this.state = BlockState.pending,
    this.translatedText,
    this.fromCache = false,
    this.error,
  });

  final BlockState state;
  final String? translatedText;
  final bool fromCache;
  final String? error;
}

/// État de lecture : document, blocs par page, traductions, réglages.
///
/// Un contrôleur par document ouvert. Tout est paresseux : on n'extrait et ne
/// traduit que les pages demandées.
class ReaderController extends ChangeNotifier {
  ReaderController({
    required TranslationService translationService,
    ReaderSettings settings = const ReaderSettings(),
  })  : _translationService = translationService,
        _settings = settings;

  final TranslationService _translationService;
  final PdfBlockExtractor _extractor = PdfBlockExtractor();
  final LanguageDetector _languageDetector = LanguageDetector();

  PdfDocument? _document;
  ReaderSettings _settings;
  String? _detectedLanguage;
  bool _preparing = false;

  final Map<int, List<TextBlock>> _blocksByPage = {};
  final Set<int> _extractingPages = {};
  final Map<String, BlockProgress> _progress = {}; // clé : id de bloc
  final Set<int> _translatedPages = {};
  int _pageCount = 0;

  /// File d'extraction : les appels PDFium (FFI synchrones) sont sérialisés
  /// pour ne pas bloquer l'isolate UI plusieurs fois en parallèle (jank).
  Future<void> _extractionQueue = Future.value();

  ReaderSettings get settings => _settings;
  int get pageCount => _pageCount;

  /// true pendant le téléchargement des modèles / la préparation du moteur :
  /// l'UI affiche un indicateur pour ne pas faire croire à un freeze.
  bool get preparing => _preparing;

  String? get detectedLanguage => _detectedLanguage;

  /// Paire de langues réellement utilisée.
  ///
  /// La langue du document est détectée automatiquement ; si l'utilisateur
  /// s'est trompé de direction (ex. document FR avec la paire EN→FR), on
  /// traduit FR→EN au lieu de produire du charabia.
  ({String from, String to}) get effectivePair {
    final detected = _detectedLanguage;
    if (detected == null) {
      return (from: _settings.sourceBcp, to: _settings.targetBcp);
    }
    if (detected == _settings.targetBcp) {
      return (from: detected, to: _settings.sourceBcp);
    }
    return (from: detected, to: _settings.targetBcp);
  }

  List<TextBlock> blocksForPage(int pageNumber) =>
      _blocksByPage[pageNumber] ?? const [];

  BlockProgress? progressFor(String blockId) => _progress[blockId];

  bool isPageTranslated(int pageNumber) =>
      _translatedPages.contains(pageNumber);

  /// À appeler une fois le document chargé par pdfrx.
  void attachDocument(PdfDocument document) {
    _document = document;
    _pageCount = document.pages.length;
    notifyListeners();
  }

  /// Met à jour les réglages. Si la paire de langues ou le moteur change,
  /// les traductions affichées ne correspondent plus : on repart de zéro.
  Future<void> updateSettings(ReaderSettings settings) async {
    final changed = settings.sourceBcp != _settings.sourceBcp ||
        settings.targetBcp != _settings.targetBcp ||
        settings.engine != _settings.engine;
    _settings = settings;
    if (changed) {
      _progress.clear();
      _translatedPages.clear();
    }
    notifyListeners();
  }

  /// Extrait les blocs de texte d'une page (idempotent, paresseux, sérialisé).
  Future<void> ensureBlocks(int pageNumber) {
    final document = _document;
    if (document == null) return Future.value();
    if (_blocksByPage.containsKey(pageNumber) ||
        _extractingPages.contains(pageNumber)) {
      return Future.value();
    }
    _extractingPages.add(pageNumber);
    final task =
        _extractionQueue.then((_) => _extract(document, pageNumber));
    _extractionQueue = task;
    return task;
  }

  Future<void> _extract(PdfDocument document, int pageNumber) async {
    try {
      final blocks = await _extractor.extractPage(document, pageNumber);
      _blocksByPage[pageNumber] = blocks;
      notifyListeners();
    } catch (e) {
      debugPrint('Extraction page $pageNumber échouée : $e');
      _blocksByPage[pageNumber] = const [];
    } finally {
      _extractingPages.remove(pageNumber);
    }
  }

  /// Détection de langue + préparation du moteur (téléchargement modèles).
  Future<void> _prepareTranslation() async {
    if (_detectedLanguage == null) {
      await ensureBlocks(1);
      final sample = blocksForPage(1).take(3).map((b) => b.text).join(' ');
      _detectedLanguage = await _languageDetector.detect(sample);
    }
    final pair = effectivePair;
    await _translationService.prepareEngine(
      _settings.engine,
      fromBcp: pair.from,
      toBcp: pair.to,
    );
  }

  /// Traduit une page. Lève une exception si la préparation échoue (l'UI
  /// l'affiche en SnackBar) ; [preparing] devient true pendant ce temps.
  Future<void> translatePage(int pageNumber) async {
    if (_preparing) return;
    _preparing = true;
    notifyListeners();
    try {
      await _prepareTranslation();
      await _translatePagePrepared(pageNumber);
    } finally {
      _preparing = false;
      notifyListeners();
    }
  }

  Future<void> _translatePagePrepared(int pageNumber) async {
    final pair = effectivePair;
    final blocks = blocksForPage(pageNumber);
    if (blocks.isEmpty) {
      _translatedPages.add(pageNumber);
      notifyListeners();
      return;
    }

    for (final block in blocks) {
      final current = _progress[block.id];
      if (current?.state == BlockState.done) continue;

      _progress[block.id] = const BlockProgress(state: BlockState.translating);
      notifyListeners();

      try {
        final result = await _translationService.translateBlock(
          block,
          engine: _settings.engine,
          fromBcp: pair.from,
          toBcp: pair.to,
        );
        _progress[block.id] = BlockProgress(
          state: BlockState.done,
          translatedText: result.translated,
          fromCache: result.fromCache,
        );
      } catch (e) {
        _progress[block.id] = BlockProgress(state: BlockState.error, error: '$e');
      }
      notifyListeners();
    }

    _translatedPages.add(pageNumber);
    notifyListeners();
  }

  /// Traduit l'intégralité du document, page par page.
  Future<void> translateWholeDocument() async {
    if (_preparing) return;
    _preparing = true;
    notifyListeners();
    try {
      await _prepareTranslation();
      for (var page = 1; page <= _pageCount; page++) {
        await ensureBlocks(page);
        await _translatePagePrepared(page);
      }
    } finally {
      _preparing = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _languageDetector.dispose();
    _document = null;
    super.dispose();
  }
}
