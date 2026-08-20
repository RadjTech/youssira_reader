import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Emplacements des modèles téléchargés / convertis (mode qualité).
///
/// Le modèle CTranslate2 d'une paire de langues est attendu dans
/// `<appSupport>/models/opus-mt-<from>-<to>-ct2/` et doit contenir :
/// - `model.bin` + `config.json` (sortie de ct2-transformers-converter) ;
/// - `sentencepiece.bpe.model` (tokenizer, depuis le repo HF d'origine).
class ModelPaths {
  static Future<String> ct2ModelDir(String fromBcp, String toBcp) async {
    final base = await getApplicationSupportDirectory();
    return p.join(base.path, 'models', 'opus-mt-$fromBcp-$toBcp-ct2');
  }

  /// true si le dossier modèle semble complet.
  static Future<bool> ct2ModelExists(String fromBcp, String toBcp) async {
    final dir = Directory(await ct2ModelDir(fromBcp, toBcp));
    if (!await dir.exists()) return false;
    final hasModelBin = await File(p.join(dir.path, 'model.bin')).exists();
    final hasTokenizer = await File(
      p.join(dir.path, 'sentencepiece.bpe.model'),
    ).exists();
    return hasModelBin && hasTokenizer;
  }

  /// Copie récursive [from] → [to] (import du modèle depuis un dossier
  /// choisi par l'utilisateur, ex. Download/).
  static Future<void> copyDirectory(String from, String to) async {
    final source = Directory(from);
    final target = Directory(to);
    if (!await target.exists()) {
      await target.create(recursive: true);
    }
    await for (final entity in source.list(recursive: false)) {
      final name = p.basename(entity.path);
      final dest = p.join(to, name);
      if (entity is File) {
        await entity.copy(dest);
      } else if (entity is Directory) {
        await copyDirectory(entity.path, dest);
      }
    }
  }
}
