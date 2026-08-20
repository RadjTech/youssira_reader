import '../models/reader_settings.dart';
import '../models/text_block.dart';
import 'cache/translation_cache.dart';
import 'translation/translation_engine.dart';

/// Résultat de la traduction d'un bloc.
class TranslationResult {
  const TranslationResult({
    required this.block,
    required this.translated,
    required this.fromCache,
    required this.elapsed,
  });

  final TextBlock block;
  final String translated;
  final bool fromCache;
  final Duration elapsed;
}

/// Orchestre la traduction d'un bloc : cache → moteur → cache.
///
/// C'est le point d'entrée unique de la couche UI pour traduire ; il choisit
/// le moteur selon [ReaderSettings.engineId] et consulte systématiquement le
/// cache SQLite avant toute inférence.
class TranslationService {
  TranslationService({required Map<String, TranslationEngine> engines})
      : _engines = engines;

  final Map<String, TranslationEngine> _engines;

  TranslationEngine engineFor(String engineId) {
    final engine = _engines[engineId];
    if (engine == null) {
      throw ArgumentError('Moteur de traduction inconnu : "$engineId"');
    }
    return engine;
  }

  /// Prépare le moteur pour la paire de langues demandée (téléchargement des
  /// modèles si nécessaire). Lève une exception en cas d'échec.
  Future<void> prepareEngine(ReaderSettings settings) async {
    await engineFor(settings.engineId)
        .ensureReady(fromBcp: settings.sourceBcp, toBcp: settings.targetBcp);
  }

  /// Traduit un bloc, en passant d'abord par le cache.
  Future<TranslationResult> translateBlock(
    TextBlock block, {
    required ReaderSettings settings,
  }) async {
    final engine = engineFor(settings.engineId);
    final key = TranslationCache.keyFor(
      text: block.text,
      fromBcp: settings.sourceBcp,
      toBcp: settings.targetBcp,
      engineId: engine.id,
    );

    final stopwatch = Stopwatch()..start();

    final cached = await TranslationCache.instance.get(key);
    if (cached != null) {
      return TranslationResult(
        block: block,
        translated: cached,
        fromCache: true,
        elapsed: stopwatch.elapsed,
      );
    }

    final translated = await engine.translate(
      block.text,
      fromBcp: settings.sourceBcp,
      toBcp: settings.targetBcp,
    );

    await TranslationCache.instance.put(
      key: key,
      sourceText: block.text,
      translatedText: translated,
      fromBcp: settings.sourceBcp,
      toBcp: settings.targetBcp,
      engineId: engine.id,
    );

    return TranslationResult(
      block: block,
      translated: translated,
      fromCache: false,
      elapsed: stopwatch.elapsed,
    );
  }
}
