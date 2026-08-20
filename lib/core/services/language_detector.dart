import 'package:google_mlkit_language_id/google_mlkit_language_id.dart';

/// Détecte la langue réelle d'un document, on-device (ML Kit Language ID).
///
/// Indispensable pour la qualité de traduction : si l'utilisateur se trompe
/// de langue source (ex. document FR avec la paire EN→FR), on corrige
/// automatiquement la direction.
class LanguageDetector {
  LanguageDetector()
      : _identifier = LanguageIdentifier(confidenceThreshold: 0.5);

  final LanguageIdentifier _identifier;

  /// Retourne le code BCP-47 court ('fr', 'en', …) ou null si la langue n'est
  /// pas déterminable (échantillon trop court, 'und').
  Future<String?> detect(String sample) async {
    final trimmed = sample.trim();
    if (trimmed.length < 20) return null;
    final code = await _identifier.identifyLanguage(trimmed);
    if (code == 'und') return null;
    // 'zh-CN' → 'zh', 'pt-BR' → 'pt' : on garde le code court pour matcher
    // les codes BCP-47 utilisés par ML Kit Translation.
    return code.split('-').first;
  }

  Future<void> dispose() => _identifier.close();
}
