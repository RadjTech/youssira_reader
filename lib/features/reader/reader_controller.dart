import 'package:flutter/foundation.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../core/models/reader_settings.dart';
import '../../core/models/text_block.dart';
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
/// Un contrôleur par document ouvert. La traduction est paresseuse : on
/// n'extrait et ne traduit que les pages demandées.
class ReaderController extends ChangeNotifier {
  ReaderController({
    required TranslationService translationService,
    ReaderSettings settings = const ReaderSettings(),
  })  : _translationService = translationService,
        _settings = settings;

  final TranslationService _translationService;
  final PdfBlockExtractor _extractor = PdfBlockExtractor();

  PdfDocument? _document;
  ReaderSettings _settings;

  final Map<int, List<TextBlock>> _blocksByPage = {};
  final Set<int> _extractingPages = {};
  final Map<String, BlockProgress> _progress = {}; // clé : id de bloc
  final Set<int> _translatedPages = {};
  int _pageCount = 0;

  ReaderSettings get settings => _settings;
  int get pageCount => _pageCount;

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

  /// File d'extraction : les appels PDFium sont sérialisés pour éviter que
  /// plusieurs pages ne bloquent l'isolate UI en même temps (jank à
  /// l'ouverture et au scroll).
  Future<void> _extractionQueue = Future.value();

  /// Extrait les blocs de texte d'une page (idempotent, paresseux).
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

  /// Traduit tous les blocs d'une page, séquentiellement, en notifiant la
  /// progression bloc par bloc (l'overlay se remplit au fil de l'eau).
  /// Lève une exception si la préparation du moteur échoue.
  Future<void> translatePage(int pageNumber) async {
    await _translationService.prepareEngine(_settings);
    await _translatePagePrepared(pageNumber);
  }

  Future<void> _translatePagePrepared(int pageNumber) async {
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
          settings: _settings,
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
    await _translationService.prepareEngine(_settings);
    for (var page = 1; page <= _pageCount; page++) {
      await ensureBlocks(page);
      await _translatePagePrepared(page);
    }
  }

  @override
  void dispose() {
    _document = null;
    super.dispose();
  }
}
