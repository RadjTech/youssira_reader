import 'services/cache/translation_cache.dart';
import 'services/monetization/ad_service.dart';
import 'services/monetization/entitlements_service.dart';
import 'services/monetization/limits_service.dart';
import 'services/monetization/monetization_config.dart';
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
  late final LimitsService limits;
  late final EntitlementsService entitlements;
  late final AdService ads;

  Future<void> init() async {
    mlkitEngine = MlkitTranslationEngine();
    nativeEngine = NativeTranslationEngine();
    translationService = TranslationService(
      engines: {
        mlkitEngine.id: mlkitEngine,
        nativeEngine.id: nativeEngine,
      },
    );
    limits = LimitsService();
    entitlements = EntitlementsService();
    ads = AdService();
    await limits.init();
    if (MonetizationConfig.devMode) return; // dev : pas de pubs/achats
    // Play Billing + AdMob : jamais bloquant, même si un service échoue.
    try {
      await entitlements.init();
    } catch (_) {}
    try {
      await ads.init();
    } catch (_) {}
  }

  /// Libère les ressources (appelé à la fermeture de l'app si besoin).
  Future<void> dispose() async {
    await mlkitEngine.dispose();
    await nativeEngine.dispose();
    await TranslationCache.instance.close();
  }
}
