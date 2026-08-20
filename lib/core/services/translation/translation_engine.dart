/// Interface commune des moteurs de traduction on-device.
///
/// Implémentations :
/// - [MlkitTranslationEngine] : mode léger (ML Kit Translation).
/// - [NativeTranslationEngine] : mode qualité (CTranslate2 via JNI).
abstract class TranslationEngine {
  /// Identifiant stable du moteur. Utilisé comme clé de cache : changer de
  /// moteur invalide de facto les traductions stockées.
  String get id;

  /// Vérifie que les modèles nécessaires sont disponibles (ex. téléchargement
  /// des modèles de langues pour ML Kit). À appeler avant [translate].
  /// Lève une exception si la préparation échoue.
  Future<void> ensureReady({required String fromBcp, required String toBcp});

  /// Traduit [text]. Le moteur doit avoir été préparé avec [ensureReady].
  Future<String> translate(
    String text, {
    required String fromBcp,
    required String toBcp,
  });

  /// Libère les ressources natives.
  Future<void> dispose();
}
