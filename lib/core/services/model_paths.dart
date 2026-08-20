import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Emplacements des modèles téléchargés / convertis (mode qualité).
///
/// Le modèle CTranslate2 d'une paire de langues est attendu dans
/// `<appSupport>/models/opus-mt-<from>-<to>-ct2/` et doit contenir :
/// - `model.bin` + `config.json` (sortie de ct2-transformers-converter) ;
/// - le tokenizer SentencePiece : `source.spm` pour les modèles Marian
///   (opus-mt, à télécharger depuis le repo HF) ou `sentencepiece.bpe.model`
///   pour NLLB.
class ModelPaths {
  /// Noms de tokenizer acceptés, par ordre de préférence.
  static const List<String> tokenizerNames = [
    'source.spm', // Marian / opus-mt
    'sentencepiece.bpe.model', // NLLB
  ];

  static Future<String> ct2ModelDir(String fromBcp, String toBcp) async {
    final base = await getApplicationSupportDirectory();
    return p.join(base.path, 'models', 'opus-mt-$fromBcp-$toBcp-ct2');
  }

  /// Retourne le nom du fichier tokenizer présent dans [dirPath], ou null.
  static Future<String?> tokenizerFileNameIn(String dirPath) async {
    for (final name in tokenizerNames) {
      if (await File(p.join(dirPath, name)).exists()) return name;
    }
    return null;
  }

  /// true si le dossier modèle semble complet.
  static Future<bool> ct2ModelExists(String fromBcp, String toBcp) async {
    final dir = Directory(await ct2ModelDir(fromBcp, toBcp));
    if (!await dir.exists()) return false;
    final hasModelBin = await File(p.join(dir.path, 'model.bin')).exists();
    final tokenizer = await tokenizerFileNameIn(dir.path);
    return hasModelBin && tokenizer != null;
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
