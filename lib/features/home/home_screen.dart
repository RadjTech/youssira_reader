import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_services.dart';
import '../../core/models/reader_settings.dart';
import '../reader/reader_controller.dart';
import '../reader/reader_screen.dart';

/// Écran d'accueil : ouvrir un PDF + documents récents.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _recentsKey = 'recent_documents';

  List<String> _recents = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadRecents();
  }

  Future<void> _loadRecents() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _recents = prefs.getStringList(_recentsKey) ?? const [];
      _loading = false;
    });
  }

  Future<void> _saveRecent(String path) async {
    final updated = [path, ..._recents.where((p) => p != path)].take(15).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_recentsKey, updated);
    if (!mounted) return;
    setState(() => _recents = updated);
  }

  Future<void> _removeRecent(String path) async {
    final updated = _recents.where((p) => p != path).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_recentsKey, updated);
    if (!mounted) return;
    setState(() => _recents = updated);
  }

  Future<void> _pickAndOpen() async {
    // file_picker utilise le sélecteur système (SAF) : pas de permission
    // de stockage à demander sur Android.
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
    final path = picked?.path;
    if (path == null) return;
    await _openDocument(path);
  }

  Future<void> _openDocument(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      await _removeRecent(path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ce fichier n\'existe plus.')),
      );
      return;
    }

    final settings = await SettingsStore.load();
    final controller = ReaderController(
      translationService: AppServices.instance.translationService,
      settings: settings,
    );

    await _saveRecent(path);
    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReaderScreen(path: path, controller: controller),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Youssira Reader'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _pickAndOpen,
        icon: const Icon(Icons.folder_open),
        label: const Text('Ouvrir un PDF'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _recents.isEmpty
              ? _buildEmptyState(theme)
              : _buildRecentsList(),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Opacity(
              opacity: 0.5,
              child: Icon(
                Icons.auto_stories_outlined,
                size: 72,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Aucun document récent',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Ouvrez un PDF : le texte est extrait avec ses coordonnées, '
              'puis traduit directement par-dessus, sans quitter votre '
              'téléphone.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecentsList() {
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 96),
      itemCount: _recents.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final path = _recents[index];
        final segments = Uri.file(path).pathSegments;
        final name = segments.isNotEmpty ? segments.last : path;
        return ListTile(
          leading: const Icon(Icons.picture_as_pdf),
          title: Text(name, overflow: TextOverflow.ellipsis),
          subtitle: Text(path, overflow: TextOverflow.ellipsis),
          onTap: () => _openDocument(path),
          trailing: IconButton(
            tooltip: 'Retirer de la liste',
            icon: const Icon(Icons.close),
            onPressed: () => _removeRecent(path),
          ),
        );
      },
    );
  }
}
