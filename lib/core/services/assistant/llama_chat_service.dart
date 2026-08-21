import 'dart:io';

import 'package:flutter/services.dart';

import '../model_paths.dart';

/// Chat local 100 % hors-ligne via llama.cpp (module natif optionnel).
///
/// Canal : "com.radjtech.youssira_reader/llama".
/// Si la bibliothèque native n'est pas compilée dans le build,
/// [isAvailable] retourne false et l'assistant est désactivé
/// (voir engine/README.md pour le build llama.cpp Android).
class LlamaChatService {
  static const MethodChannel _channel =
      MethodChannel('com.radjtech.youssira_reader/llama');

  bool? _available;

  /// Indique si le module natif llama.cpp est présent dans le build.
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

  /// Charge le modèle GGUF en mémoire (une seule fois).
  Future<void> initialize({int nCtx = 4096}) async {
    if (!await isAvailable()) {
      throw StateError(
        "Le module natif llama.cpp n'est pas disponible dans ce build. "
        'Voir engine/README.md pour le compiler.',
      );
    }
    final modelPath = await ModelPaths.llmModelPath();
    if (!await File(modelPath).exists()) {
      throw StateError(
        'Modèle LLM absent : téléchargez-le ou importez un GGUF '
        "depuis l'écran Assistant.",
      );
    }
    final ok = await _channel.invokeMethod<bool>('initialize', {
      'modelPath': modelPath,
      'nCtx': nCtx,
    });
    if (ok != true) {
      throw StateError('Chargement du modèle LLM impossible : $modelPath');
    }
  }

  /// Un échange de chat (système + utilisateur) → réponse complète.
  Future<String> chat({
    required String system,
    required String user,
  }) async {
    final answer = await _channel.invokeMethod<String>('chat', {
      'system': system,
      'user': user,
    });
    if (answer == null) {
      throw StateError(
        "Le modèle n'a pas répondu (voir logcat youssira_llama).",
      );
    }
    return answer.trim();
  }

  Future<void> shutdown() => _channel.invokeMethod<void>('shutdown');

  /// Télécharge le modèle GGUF par défaut avec progression (0..1).
  /// Reprise non gérée (v1) ; fichier temporaire puis renommage atomique.
  static Future<void> downloadModel(
    void Function(double progress, int bytesDone, int? bytesTotal) onProgress,
  ) async {
    final target = File(await ModelPaths.llmModelPath());
    if (await target.exists()) return;
    await target.parent.create(recursive: true);

    final tmp = File('${target.path}.part');
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(ModelPaths.llmDownloadUrl));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode} sur le modèle LLM');
      }
      final total = response.contentLength > 0 ? response.contentLength : null;
      final sink = tmp.openWrite();
      var done = 0;
      await for (final chunk in response) {
        sink.add(chunk);
        done += chunk.length;
        onProgress(
          total == null ? 0.0 : (done / total).clamp(0.0, 1.0),
          done,
          total,
        );
      }
      await sink.flush();
      await sink.close();
      await tmp.rename(target.path);
    } finally {
      client.close(force: true);
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
    }
  }
}
