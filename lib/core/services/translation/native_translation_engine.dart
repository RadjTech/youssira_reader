import 'package:flutter/services.dart';

import '../model_paths.dart';
import 'translation_engine.dart';

/// Mode « qualité » : CTranslate2 + opus-mt / NLLB (quantifiés int8), appelés
/// via un MethodChannel vers le module natif Kotlin/JNI (voir dossier
/// `engine/` à la racine du projet).
///
/// Ce moteur est optionnel : si la bibliothèque native n'est pas compilée,
/// [isAvailable] retourne false et l'UI propose uniquement le mode léger.
class NativeTranslationEngine implements TranslationEngine {
  static const MethodChannel _channel =
      MethodChannel('com.radjtech.youssira_reader/translation');

  bool? _available;

  @override
  String get id => 'ct2-quality';

  /// Indique si le module natif est présent dans le build.
  Future<bool> isAvailable() async {
    final cached = _available;
    if (cached != null) return cached;
    try {
      _available = await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      _available = false;
    } on PlatformException {
      _available = false;
    }
    return _available!;
  }

  @override
  Future<void> ensureReady({
    required String fromBcp,
    required String toBcp,
  }) async {
    if (!await isAvailable()) {
      throw StateError(
        'Le moteur natif CTranslate2 n\'est pas disponible dans ce build. '
        'Voir engine/README.md pour le compiler.',
      );
    }
    final modelDir = await ModelPaths.ct2ModelDir(fromBcp, toBcp);
    final ok = await _channel.invokeMethod<bool>('initialize', {
      'sourceLang': fromBcp,
      'targetLang': toBcp,
      'modelDir': modelDir,
    });
    if (ok != true) {
      throw StateError(
        'Modèle CTranslate2 introuvable ou invalide dans $modelDir. '
        'Convertissez opus-mt avec ct2-transformers-converter '
        '(voir engine/README.md).',
      );
    }
  }

  @override
  Future<String> translate(
    String text, {
    required String fromBcp,
    required String toBcp,
  }) async {
    if (text.trim().isEmpty) return text;
    final result = await _channel.invokeMethod<String>('translate', {
      'text': text,
      'sourceLang': fromBcp,
      'targetLang': toBcp,
    });
    if (result == null) {
      throw StateError('Le moteur natif a retourné un résultat nul.');
    }
    return result;
  }

  @override
  Future<void> dispose() async {
    if (_available == true) {
      await _channel.invokeMethod<void>('shutdown');
    }
  }
}
