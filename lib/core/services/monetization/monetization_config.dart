/// Réglages de monétisation (freemium + AdMob).
///
/// Les identifiants ci-dessous sont les IDs de TEST Google. Avant
/// publication, remplacez-les par vos IDs réels (README §Monétisation) :
/// - APPLICATION_ID dans AndroidManifest.xml ;
/// - interstitialUnitId / rewardedUnitId ci-dessous.
class MonetizationConfig {
  /// MODE DÉVELOPPEMENT : true = pubs, quotas et achats totalement
  /// désactivés (tests illimités, zéro dépendance AdMob/Play Billing).
  /// Repasser à false avant publication.
  static const bool devMode = true;

  // IDs de test Google (Android).
  static const interstitialUnitId = 'ca-app-pub-3940256099942544/1033173712';
  static const rewardedUnitId = 'ca-app-pub-3940256099942544/5224354917';

  // --- Limites gratuites, par jour -----------------------------------
  static const freePagesPerDay = 30;
  static const freeExportsPerDay = 1;
  static const freeQuestionsPerDay = 5;

  // --- Bonus accordés par publicité récompensée ----------------------
  static const rewardPages = 30;
  static const rewardExports = 1;
  static const rewardQuestions = 5;
}
