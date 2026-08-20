import 'services/cache/translation_cache.dart';
import 'services/translation/mlkit_translation_engine.dart';
import 'services/translation/native_translation_engine.dart';
import 'services/translation_service.dart';

/// Services globaux de l'application (singletons), initialisés dans main().
class AppServices {
  AppServices._();

  static final AppServices instance = AppServices._();

  late final MlkitTranslationEngine mlkitEngine;
  late final NativeTranslationEngine nativeEngine;
  late final TranslationService translationService;

  Future<void> init() async {
    mlkitEngine = MlkitTranslationEngine();
    nativeEngine = NativeTranslationEngine();
    translationService = TranslationService(
      engines: {
        mlkitEngine.id: mlkitEngine,
        nativeEngine.id: nativeEngine,
      },
    );
  }

  /// Libère les ressources (appelé à la fermeture de l'app si besoin).
  Future<void> dispose() async {
    await mlkitEngine.dispose();
    await nativeEngine.dispose();
    await TranslationCache.instance.close();
  }
}
