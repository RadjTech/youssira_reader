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

  /// Liste les modèles CTranslate2 convertis présents sur le disque.
  static Future<List<({String from, String to, String path, int sizeBytes})>>
      listCt2Models() async {
    final base = await getApplicationSupportDirectory();
    final modelsDir = Directory(p.join(base.path, 'models'));
    final out = <({String from, String to, String path, int sizeBytes})>[];
    if (!await modelsDir.exists()) return out;
    final re = RegExp(r'^opus-mt-([a-z]{2,3})-([a-z]{2,3})-ct2$');
    await for (final entity in modelsDir.list()) {
      if (entity is! Directory) continue;
      final m = re.firstMatch(p.basename(entity.path));
      if (m == null) continue;
      out.add((
        from: m.group(1)!,
        to: m.group(2)!,
        path: entity.path,
        sizeBytes: await directorySizeBytes(entity.path),
      ));
    }
    return out;
  }

  /// Taille totale (octets) d'une arborescence.
  static Future<int> directorySizeBytes(String path) async {
    var total = 0;
    await for (final entity in Directory(path).list(recursive: true)) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }

  /// Supprime récursivement un dossier (désinstallation d'un modèle).
  static Future<void> deleteDirectory(String path) =>
      Directory(path).delete(recursive: true);

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
