import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Emplacements des modèles téléchargés / convertis (mode qualité).
///
/// Le modèle CTranslate2 d'une paire de langues est attendu dans
/// `<appSupport>/models/opus-mt-<from>-<to>-ct2/` (dossier produit par
/// `ct2-transformers-converter`, voir engine/README.md).
class ModelPaths {
  static Future<String> ct2ModelDir(String fromBcp, String toBcp) async {
    final base = await getApplicationSupportDirectory();
    return p.join(base.path, 'models', 'opus-mt-$fromBcp-$toBcp-ct2');
  }
}
