import 'dart:async';

import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'monetization_config.dart';

/// AdMob : consentement UMP + interstitiel (après export) + pub récompensée
/// (déblocage des limites). Toujours gracieux : hors-ligne ou sans pub
/// disponible, rien ne bloque l'app.
class AdService {
  InterstitialAd? _interstitial;
  RewardedAd? _rewarded;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    // Consentement (UMP, API google_mobile_ads 5.x) avant d'initialiser les
    // pubs. Callbacks enveloppés dans des Completer avec timeout : jamais
    // bloquant hors-ligne.
    try {
      final updated = Completer<bool>();
      ConsentInformation.instance.requestConsentInfoUpdate(
        ConsentRequestParameters(tagForUnderAgeOfConsent: false),
        () {
          if (!updated.isCompleted) updated.complete(true);
        },
        (_) {
          if (!updated.isCompleted) updated.complete(false);
        },
      );
      final ok = await updated.future
          .timeout(const Duration(seconds: 10), onTimeout: () => false);
      if (ok &&
          await ConsentInformation.instance.isConsentFormAvailable()) {
        final dismissed = Completer<void>();
        await ConsentForm.loadAndShowConsentFormIfRequired((_) {
          if (!dismissed.isCompleted) dismissed.complete();
        });
        await dismissed.future
            .timeout(const Duration(minutes: 5), onTimeout: () {});
      }
    } catch (_) {
      // Jamais bloquant : sans consentement on servira des pubs
      // non personnalisées, ou rien du tout hors-ligne.
    }
    try {
      await MobileAds.instance.initialize();
    } catch (_) {
      // Appareil sans Play Services (émulateur…) : pas de pubs, jamais
      // bloquant.
      return;
    }
    _initialized = true;
    _loadInterstitial();
    _loadRewarded();
  }

  void _loadInterstitial() {
    InterstitialAd.load(
      adUnitId: MonetizationConfig.interstitialUnitId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) => _interstitial = ad,
        onAdFailedToLoad: (_) => _interstitial = null,
      ),
    );
  }

  void _loadRewarded() {
    RewardedAd.load(
      adUnitId: MonetizationConfig.rewardedUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) => _rewarded = ad,
        onAdFailedToLoad: (_) => _rewarded = null,
      ),
    );
  }

  bool get hasRewarded => _rewarded != null;

  /// Interstitiel après un export réussi. Retourne true si affiché.
  Future<bool> showInterstitial() async {
    final ad = _interstitial;
    if (ad == null) return false;
    _interstitial = null;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (a) {
        a.dispose();
        _loadInterstitial();
      },
      onAdFailedToShowFullScreenContent: (a, e) {
        a.dispose();
        _loadInterstitial();
      },
    );
    await ad.show();
    return true;
  }

  /// Pub récompensée. true si l'utilisateur a gagné la récompense.
  Future<bool> showRewarded() async {
    final ad = _rewarded;
    if (ad == null) return false;
    _rewarded = null;
    final completer = Completer<bool>();
    var earned = false;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (a) {
        a.dispose();
        _loadRewarded();
        if (!completer.isCompleted) completer.complete(earned);
      },
      onAdFailedToShowFullScreenContent: (a, e) {
        a.dispose();
        _loadRewarded();
        if (!completer.isCompleted) completer.complete(false);
      },
    );
    await ad.show(
      onUserEarnedReward: (ad, reward) => earned = true,
    );
    return completer.future;
  }
}
