import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import 'translation_engine.dart';

/// Mode « léger » : ML Kit On-Device Translation.
///
/// - ~30 Mo par langue, modèles gérés/téléchargés par Google Play Services ;
/// - très rapide, fonctionne dès 2 Go de RAM ;
/// - qualité correcte pour de la lecture courante.
class MlkitTranslationEngine implements TranslationEngine {
  final OnDeviceTranslatorModelManager _modelManager =
      OnDeviceTranslatorModelManager();
  final Map<String, OnDeviceTranslator> _translators = {};

  @override
  String get id => 'mlkit-light';

  static TranslateLanguage _languageFromBcp(String bcp) {
    return TranslateLanguage.values.firstWhere(
      (language) => language.bcpCode == bcp,
      orElse: () =>
          throw ArgumentError('Langue non supportée par ML Kit : "$bcp"'),
    );
  }

  @override
  Future<void> ensureReady({
    required String fromBcp,
    required String toBcp,
  }) async {
    for (final bcp in {fromBcp, toBcp}) {
      final downloaded = await _modelManager.isModelDownloaded(bcp);
      if (!downloaded) {
        final ok = await _modelManager.downloadModel(bcp);
        if (!ok) {
          throw StateError(
            'Impossible de télécharger le modèle de langue "$bcp" '
            '(connexion requise la première fois).',
          );
        }
      }
    }
  }

  Future<OnDeviceTranslator> _translator(String fromBcp, String toBcp) async {
    final key = '$fromBcp>$toBcp';
    final existing = _translators[key];
    if (existing != null) return existing;

    final translator = OnDeviceTranslator(
      sourceLanguage: _languageFromBcp(fromBcp),
      targetLanguage: _languageFromBcp(toBcp),
    );
    _translators[key] = translator;
    return translator;
  }

  @override
  Future<String> translate(
    String text, {
    required String fromBcp,
    required String toBcp,
  }) async {
    if (text.trim().isEmpty) return text;
    final translator = await _translator(fromBcp, toBcp);
    return translator.translateText(text);
  }

  @override
  Future<void> dispose() async {
    for (final translator in _translators.values) {
      await translator.close();
    }
    _translators.clear();
  }
}
