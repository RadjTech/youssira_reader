import 'package:flutter/material.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import '../../core/models/reader_settings.dart';
import '../../core/services/model_paths.dart';

/// Gestion des modèles de langue installés, selon les besoins :
/// - ML Kit (mode Léger) : téléchargement / suppression par langue (~30 Mo) ;
/// - CTranslate2 (mode Qualité) : inventaire des modèles convertis importés,
///   taille sur disque, suppression.
class LanguageModelsScreen extends StatefulWidget {
  const LanguageModelsScreen({super.key});

  @override
  State<LanguageModelsScreen> createState() => _LanguageModelsScreenState();
}

class _LanguageModelsScreenState extends State<LanguageModelsScreen> {
  final OnDeviceTranslatorModelManager _manager =
      OnDeviceTranslatorModelManager();
  final Map<String, bool> _downloaded = {};
  final Set<String> _busy = {};
  List<({String from, String to, String path, int sizeBytes})> _ct2 = const [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    for (final code in LanguageCatalog.supported.keys) {
      try {
        final ok = await _manager.isModelDownloaded(code);
        if (!mounted) return;
        setState(() => _downloaded[code] = ok);
      } catch (_) {
        // Gestionnaire indisponible (émulateur sans Play Services…) :
        // on laisse l'état inconnu.
      }
    }
    final ct2 = await ModelPaths.listCt2Models();
    if (!mounted) return;
    setState(() => _ct2 = ct2);
  }

  Future<void> _download(String code) async {
    setState(() => _busy.add(code));
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _manager.downloadModel(code, isWifiRequired: false);
      if (!mounted) return;
      setState(() => _downloaded[code] = true);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Modèle ${LanguageCatalog.supported[code]} installé.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Téléchargement impossible : $e')),
      );
    } finally {
      if (mounted) setState(() => _busy.remove(code));
    }
  }

  Future<void> _deleteMlkit(String code) async {
    setState(() => _busy.add(code));
    try {
      await _manager.deleteModel(code);
      if (!mounted) return;
      setState(() => _downloaded[code] = false);
    } finally {
      if (mounted) setState(() => _busy.remove(code));
    }
  }

  Future<void> _deleteCt2(String path) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer ce modèle ?'),
        content: const Text(
          'Le modèle converti sera définitivement supprimé de l'appareil.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await ModelPaths.deleteDirectory(path);
    await _refresh();
  }

  String _mo(int bytes) => '${(bytes / 1048576).toStringAsFixed(0)} Mo';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Modèles de langue')),
      body: ListView(
        children: [
          _sectionHeader('ML Kit — mode Léger (~30 Mo par langue)'),
          for (final entry in LanguageCatalog.supported.entries)
            ListTile(
              title: Text(entry.value),
              subtitle: Text(
                _downloaded[entry.key] == true
                    ? 'Modèle installé'
                    : _downloaded.containsKey(entry.key)
                        ? 'Non installé'
                        : 'Vérification…',
              ),
              trailing: _busy.contains(entry.key)
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : _downloaded[entry.key] == true
                      ? IconButton(
                          tooltip: 'Supprimer le modèle',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _deleteMlkit(entry.key),
                        )
                      : OutlinedButton(
                          onPressed: () => _download(entry.key),
                          child: const Text('Installer'),
                        ),
            ),
          const Divider(height: 32),
          _sectionHeader('CTranslate2 — mode Qualité (modèles convertis)'),
          if (_ct2.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Aucun modèle converti importé.\n'
                'Réglages → « Importer un modèle converti » après conversion '
                'sur PC (voir engine/README.md).',
              ),
            ),
          for (final model in _ct2)
            ListTile(
              leading: const Icon(Icons.memory),
              title: Text(
                '${model.from.toUpperCase()} → ${model.to.toUpperCase()}',
              ),
              subtitle: Text('opus-mt • ${_mo(model.sizeBytes)} sur disque'),
              trailing: IconButton(
                tooltip: 'Supprimer le modèle',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _deleteCt2(model.path),
              ),
            ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}
