import '../models/reader_settings.dart';
import '../models/text_block.dart';
import 'cache/translation_cache.dart';
import 'translation/text_normalizer.dart';
import 'translation/text_protector.dart';
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

/// Orchestre la traduction d'un bloc : protection des noms propres / URLs /
/// versions → cache → moteur → cache.
///
/// Les langues sont passées explicitement : c'est le [ReaderController] qui
/// décide de la paire effective (détection automatique de la langue du
/// document, correction de direction si besoin).
class TranslationService {
  TranslationService({required Map<String, TranslationEngine> engines})
      : _engines = engines;

  final Map<String, TranslationEngine> _engines;

  TranslationEngine engineFor(TranslationEngineKind kind) {
    final engine = _engines[kind.id];
    if (engine == null) {
      throw ArgumentError('Moteur de traduction inconnu : "${kind.id}"');
    }
    return engine;
  }

  /// Prépare le moteur pour la paire de langues demandée (téléchargement des
  /// modèles si nécessaire). Lève une exception en cas d'échec.
  Future<void> prepareEngine(
    TranslationEngineKind kind, {
    required String fromBcp,
    required String toBcp,
  }) {
    return engineFor(kind).ensureReady(fromBcp: fromBcp, toBcp: toBcp);
  }

  /// Traduit un bloc : les URLs, emails, versions et noms de marques /
  /// technos / langages sont masqués avant l'inférence puis restaurés, pour
  /// une traduction « intelligente » qui ne touche pas à ces éléments.
  Future<TranslationResult> translateBlock(
    TextBlock block, {
    required TranslationEngineKind engine,
    required String fromBcp,
    required String toBcp,
  }) async {
    final impl = engineFor(engine);
    final key = TranslationCache.keyFor(
      text: TextNormalizer.normalize(block.text),
      fromBcp: fromBcp,
      toBcp: toBcp,
      engineId: impl.id,
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

    final masked = TextProtector.mask(TextNormalizer.normalize(block.text));
    final rawTranslated =
        await impl.translate(masked.masked, fromBcp: fromBcp, toBcp: toBcp);
    final translated = TextProtector.restore(rawTranslated, masked);

    await TranslationCache.instance.put(
      key: key,
      sourceText: block.text,
      translatedText: translated,
      fromBcp: fromBcp,
      toBcp: toBcp,
      engineId: impl.id,
    );

    return TranslationResult(
      block: block,
      translated: translated,
      fromCache: false,
      elapsed: stopwatch.elapsed,
    );
  }
}
