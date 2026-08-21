import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../core/models/reader_settings.dart';
import 'pro_screen.dart';
import '../../core/services/cache/translation_cache.dart';
import '../../core/services/model_paths.dart';
import 'language_models_screen.dart';

/// Réglages : langues, moteur de traduction, opacité de l'overlay, cache.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.settings});

  final ReaderSettings settings;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late ReaderSettings _settings = widget.settings;
  bool _checkingNative = true;
  bool _nativeAvailable = false;
  bool _modelPresent = false;
  bool _importing = false;
  int _cacheCount = 0;

  @override
  void initState() {
    super.initState();
    _checkNativeEngine();
    _loadCacheCount();
    _checkModel();
  }

  Future<void> _checkModel() async {
    final present = await ModelPaths.ct2ModelExists(
      _settings.sourceBcp,
      _settings.targetBcp,
    );
    if (!mounted) return;
    setState(() => _modelPresent = present);
  }

  Future<void> _checkNativeEngine() async {
    final available = await AppServices.instance.nativeEngine.isAvailable();
    if (!mounted) return;
    setState(() {
      _nativeAvailable = available;
      _checkingNative = false;
    });
    // Si le mode qualité était sélectionné mais que le module natif est
    // absent, on retombe sur le mode léger.
    if (!available && _settings.engine == TranslationEngineKind.ct2Quality) {
      setState(() {
        _settings = _settings.copyWith(engine: TranslationEngineKind.mlkitLight);
      });
    }
  }

  Future<void> _loadCacheCount() async {
    final count = await TranslationCache.instance.count();
    if (!mounted) return;
    setState(() => _cacheCount = count);
  }

  /// Importe le modèle CTranslate2 depuis un dossier choisi par
  /// l'utilisateur (SAF) vers le dossier privé de l'app.
  Future<void> _importModel() async {
    final messenger = ScaffoldMessenger.of(context);
    final dirPath = await FilePicker.getDirectoryPath();
    if (dirPath == null) return;

    setState(() => _importing = true);
    try {
      final target = await ModelPaths.ct2ModelDir(
        _settings.sourceBcp,
        _settings.targetBcp,
      );
      await ModelPaths.copyDirectory(dirPath, target);
      await _checkModel();
      messenger.showSnackBar(
        SnackBar(content: Text('Modèle importé dans $target')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Import impossible : $e')),
      );
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _clearCache() async {
    await TranslationCache.instance.clear();
    await _loadCacheCount();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Cache des traductions vidé.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Réglages'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(_settings),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
      body: ListView(
        children: [
          _sectionHeader('Langues'),
          _languageDropdown(
            label: 'Langue du document',
            value: _settings.sourceBcp,
            onChanged: (value) =>
                setState(() => _settings = _settings.copyWith(sourceBcp: value)),
          ),
          _languageDropdown(
            label: 'Traduire vers',
            value: _settings.targetBcp,
            onChanged: (value) =>
                setState(() => _settings = _settings.copyWith(targetBcp: value)),
          ),
          ListTile(
            leading: const Icon(Icons.language),
            title: const Text('Modèles de langue'),
            subtitle: const Text(
              'Installer / supprimer les modèles selon vos besoins de langues.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LanguageModelsScreen()),
            ),
          ),
          const Divider(height: 32),
          _sectionHeader('Moteur de traduction'),
          RadioGroup<TranslationEngineKind>(
            groupValue: _settings.engine,
            onChanged: (value) {
              if (value == null) return;
              setState(() => _settings = _settings.copyWith(engine: value));
            },
            child: Column(
              children: [
                const RadioListTile<TranslationEngineKind>(
                  title: Text('Léger — ML Kit'),
                  subtitle: Text(
                    '~30 Mo par langue, très rapide, téléchargé par Google '
                    'Play Services. Recommandé.',
                  ),
                  value: TranslationEngineKind.mlkitLight,
                ),
                RadioListTile<TranslationEngineKind>(
                  title: const Text('Qualité — CTranslate2'),
                  subtitle: Text(
                    _checkingNative
                        ? 'Vérification du module natif…'
                        : _nativeAvailable
                            ? 'Modèles opus-mt / NLLB int8, meilleure qualité.'
                            : 'Module natif non compilé dans ce build — '
                                'voir engine/README.md.',
                  ),
                  value: TranslationEngineKind.ct2Quality,
                  enabled: _nativeAvailable && !_checkingNative,
                ),
              ],
            ),
          ),
          ListTile(
            leading: _importing
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.folder_open),
            title: const Text('Importer un modèle converti'),
            subtitle: Text(
              _modelPresent
                  ? 'Modèle ${_settings.sourceBcp}→${_settings.targetBcp} présent ✓'
                  : 'Choisis le dossier opus-mt-…-ct2 (model.bin + '
                      'source.spm), ex. depuis Download/.',
            ),
            trailing: OutlinedButton(
              onPressed: _importing ? null : _importModel,
              child: const Text('Importer'),
            ),
          ),
          const Divider(height: 32),
          _sectionHeader('Version Premium'),
          ListTile(
            leading: const Icon(Icons.workspace_premium_outlined),
            title: const Text('Youssira Pro'),
            subtitle: Text(
              AppServices.instance.entitlements.isPro
                  ? 'Pro actif : sans pub, illimité ✓'
                  : 'Sans pub, tout illimité (mensuel ou à vie).',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ProScreen()),
            ),
          ),
          const Divider(height: 32),
          _sectionHeader('Calque de traduction'),
          ListTile(
            title: const Text('Opacité du fond'),
            subtitle: Slider(
              value: _settings.overlayOpacity,
              min: 0.5,
              max: 1.0,
              divisions: 10,
              label: '${(_settings.overlayOpacity * 100).round()}%',
              onChanged: (value) => setState(
                () => _settings = _settings.copyWith(overlayOpacity: value),
              ),
            ),
          ),
          const Divider(height: 32),
          _sectionHeader('Cache'),
          ListTile(
            title: const Text('Traductions en cache'),
            subtitle: Text('$_cacheCount entrées'),
            trailing: OutlinedButton.icon(
              onPressed: _cacheCount > 0 ? _clearCache : null,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Vider'),
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

  Widget _languageDropdown({
    required String label,
    required String value,
    required ValueChanged<String?> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: DropdownButtonFormField<String>(
        initialValue: value,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        items: [
          for (final entry in LanguageCatalog.supported.entries)
            DropdownMenuItem(
              value: entry.key,
              child: Text('${entry.value} (${entry.key})'),
            ),
        ],
        onChanged: onChanged,
      ),
    );
  }
}
