import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../core/app_services.dart';
import '../../core/models/reader_settings.dart';
import '../../core/models/text_block.dart';
import '../../core/services/language_detector.dart';
import '../../core/services/pdf_block_extractor.dart';
import '../../core/services/pdf_export_service.dart';
import '../../core/services/translation/code_detector.dart';
import '../../core/services/translation/text_protector.dart';
import '../../core/services/translation_service.dart';

/// État de traduction d'un bloc.
enum BlockState { pending, translating, done, error, skipped }

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
  String? _filePath;
  ReaderSettings _settings;
  String? _detectedLanguage;
  bool _preparing = false; // téléchargement modèles / préparation moteur
  bool _busy = false; // opération de traduction en cours

  // Progression « traduire tout le document ».
  bool _docRunning = false;
  bool _docAnalyzing = false;
  bool _docCancel = false;
  int _docTotalBlocks = 0;
  int _docDoneBlocks = 0;

  final Map<int, List<TextBlock>> _blocksByPage = {};
  final Set<int> _extractingPages = {};
  final Map<String, BlockProgress> _progress = {}; // clé : id de bloc
  final Set<int> _translatedPages = {};
  int _pageCount = 0;

  // Mode « document traduit » (Xodo) : PDF recomposé, généré à la demande.
  String? _translatedDocPath;
  bool _generatingDoc = false;
  int _resolvedCount = 0; // blocs done/skipped (détecte un document périmé)
  int _genRevision = -1;

  /// File d'extraction : les appels PDFium (FFI synchrones) sont sérialisés
  /// pour ne pas bloquer l'isolate UI plusieurs fois en parallèle (jank).
  Future<void> _extractionQueue = Future.value();

  ReaderSettings get settings => _settings;
  int get pageCount => _pageCount;

  /// true UNIQUEMENT pendant la préparation du moteur (détection de langue +
  /// téléchargement des modèles) : l'UI affiche « téléchargement… ».
  bool get preparing => _preparing;

  /// true pendant toute opération de traduction (page ou document).
  bool get busy => _busy;

  /// true pendant « traduire tout le document » (analyse + traduction).
  bool get docRunning => _docRunning;

  /// true pendant la phase d'analyse (extraction des blocs de toutes les
  /// pages) qui précède la traduction du document entier.
  bool get docAnalyzing => _docAnalyzing;

  /// Progression 0..1 de la traduction du document entier.
  double get docProgress => _docTotalBlocks <= 0
      ? 0.0
      : (_docDoneBlocks / _docTotalBlocks).clamp(0.0, 1.0);

  int get docDoneBlocks => _docDoneBlocks;
  int get docTotalBlocks => _docTotalBlocks;

  /// Demande l'arrêt de la traduction du document entier.
  void cancelDocumentTranslation() {
    _docCancel = true;
  }

  /// true si des blocs de la page sont en cours de traduction : l'UI
  /// affiche « traduction en cours… » (les calques arrivent au fil de l'eau).
  bool isTranslatingPage(int pageNumber) {
    return blocksForPage(pageNumber).any(
      (b) => _progress[b.id]?.state == BlockState.translating,
    );
  }

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

  /// Chemin du PDF recomposé (« document traduit »), null avant génération.
  String? get translatedDocPath => _translatedDocPath;

  bool get generatingDoc => _generatingDoc;

  /// true si des traductions ont progressé depuis la dernière génération :
  /// l'UI propose alors de régénérer le document traduit.
  bool get translatedDocStale =>
      _translatedDocPath != null && _genRevision != _resolvedCount;

  BlockProgress? progressFor(String blockId) => _progress[blockId];

  bool isPageTranslated(int pageNumber) =>
      _translatedPages.contains(pageNumber);

  /// À appeler une fois le document chargé par pdfrx.
  /// [filePath] permet l'extraction du style réel via l'API C de PDFium.
  void attachDocument(PdfDocument document, String filePath) {
    _document = document;
    _filePath = filePath;
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
      _resolvedCount = 0;
      _translatedDocPath = null; // document recomposé = périmé
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
      final blocks = await _extractor.extractPage(
        document,
        pageNumber,
        filePath: _filePath,
      );
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
      try {
        _detectedLanguage = await _languageDetector.detect(sample);
      } catch (e) {
        // La détection est un confort : si elle échoue (modèle absent,
        // échantillon vide…), on traduit avec la paire des réglages.
        debugPrint('Détection de langue échouée : $e');
        _detectedLanguage = null;
      }
    }
    final pair = effectivePair;
    await _translationService.prepareEngine(
      _settings.engine,
      fromBcp: pair.from,
      toBcp: pair.to,
    );
  }

  /// Exécute [fn] avec [preparing] = true (phase de préparation uniquement).
  Future<T> _withPreparing<T>(Future<T> Function() fn) async {
    _preparing = true;
    notifyListeners();
    try {
      return await fn();
    } finally {
      _preparing = false;
      notifyListeners();
    }
  }

  /// Traduit une page. Lève une exception si la préparation échoue (l'UI
  /// l'affiche en SnackBar).
  /// - [preparing] : vrai pendant détection + téléchargement des modèles ;
  /// - [busy] : vrai pendant toute l'opération (traduction des blocs).
  Future<void> translatePage(int pageNumber) async {
    if (_busy) return;
    _busy = true;
    notifyListeners();
    try {
      await _withPreparing(() => _prepareTranslation());
      await _translatePagePrepared(pageNumber);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _translatePagePrepared(
    int pageNumber, {
    void Function()? onBlockResolved,
    bool Function()? shouldStop,
  }) async {
    final pair = effectivePair;
    final blocks = blocksForPage(pageNumber);
    if (blocks.isEmpty) {
      _translatedPages.add(pageNumber);
      notifyListeners();
      return;
    }

    // Quota gratuit journalier (Pro = illimité). Lève
    // QuotaExceededException que l'UI transforme en dialogue
    // pub récompensée / Pro.
    if (!AppServices.instance.entitlements.isPro) {
      AppServices.instance.limits.tryConsumePage();
    }

    for (final block in blocks) {
      if (shouldStop != null && shouldStop()) break;
      final current = _progress[block.id];
      if (current?.state == BlockState.done ||
          current?.state == BlockState.skipped) {
        continue;
      }

      // Traduction intelligente : le code source et les blocs composés
      // uniquement de noms protégés (marques, technos, URLs…) restent intacts.
      if (CodeDetector.looksLikeCode(block.text) ||
          TextProtector.shouldSkip(block.text)) {
        _progress[block.id] = const BlockProgress(state: BlockState.skipped);
        _resolvedCount++;
        onBlockResolved?.call();
        notifyListeners();
        continue;
      }

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
        _resolvedCount++;
      } catch (e) {
        _progress[block.id] = BlockProgress(state: BlockState.error, error: '$e');
      }
      onBlockResolved?.call();
      notifyListeners();
    }

    _translatedPages.add(pageNumber);
    notifyListeners();
  }

  /// Traduit l'intégralité du document, page par page, avec progression :
  /// 1) analyse (extraction des blocs de toutes les pages, comptage) ;
  /// 2) traduction bloc par bloc ([docProgress] monte à chaque bloc résolu).
  Future<void> translateWholeDocument() async {
    if (_busy) return;
    _busy = true;
    _docRunning = true;
    _docAnalyzing = true;
    _docCancel = false;
    _docTotalBlocks = 0;
    _docDoneBlocks = 0;
    notifyListeners();
    try {
      await _withPreparing(() => _prepareTranslation());
      if (_docCancel) return;

      for (var page = 1; page <= _pageCount; page++) {
        if (_docCancel) return;
        await ensureBlocks(page);
      }
      for (var page = 1; page <= _pageCount; page++) {
        for (final block in blocksForPage(page)) {
          _docTotalBlocks++;
          final state = _progress[block.id]?.state;
          if (state == BlockState.done || state == BlockState.skipped) {
            _docDoneBlocks++;
          }
        }
      }
      _docAnalyzing = false;
      notifyListeners();

      for (var page = 1; page <= _pageCount; page++) {
        if (_docCancel) break;
        await _translatePagePrepared(
          page,
          onBlockResolved: () {
            _docDoneBlocks++;
            notifyListeners();
          },
          shouldStop: () => _docCancel,
        );
      }
    } finally {
      _docRunning = false;
      _docAnalyzing = false;
      _busy = false;
      notifyListeners();
    }
  }

  /// Mode « document traduit » (Xodo) : traduit tout le document si
  /// nécessaire, puis compose le PDF recomposé (pages en image + texte
  /// traduit reflowé) et l'enregistre pour ouverture dans le viewer.
  Future<void> openTranslatedDocument() async {
    if (_generatingDoc) return;
    final path = _filePath;
    if (path == null) return;
    if (_translatedDocPath != null && !translatedDocStale) {
      notifyListeners();
      return;
    }
    _generatingDoc = true;
    notifyListeners();
    try {
      final allTranslated = [
        for (var i = 1; i <= _pageCount; i++) isPageTranslated(i),
      ].every((e) => e);
      if (!allTranslated) {
        await translateWholeDocument();
      }

      final dir = await getTemporaryDirectory();
      final out =
          '${dir.path}/youssira_traduit_${path.hashCode.toUnsigned(32).toRadixString(16)}_${effectivePair.to}.pdf';

      // Progression affichée par la bannière existante (pages composées).
      _docRunning = true;
      _docAnalyzing = false;
      _docTotalBlocks = _pageCount;
      _docDoneBlocks = 0;
      notifyListeners();
      await PdfExportService.buildTranslatedPdfToFile(
        sourcePath: path,
        controller: this,
        outPath: out,
        onProgress: (p, label) {
          if (p != null) {
            _docDoneBlocks = (p * _docTotalBlocks).round().clamp(0, _docTotalBlocks);
          }
          notifyListeners();
        },
      );
      _translatedDocPath = out;
      _genRevision = _resolvedCount;
    } catch (e) {
      debugPrint('Génération du document traduit échouée : $e');
    } finally {
      _docRunning = false;
      _generatingDoc = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _languageDetector.dispose();
    _document = null;
    _filePath = null;
    super.dispose();
  }
}
