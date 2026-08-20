import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:provider/provider.dart';

import '../../core/models/reader_settings.dart';
import '../settings/settings_screen.dart';
import 'reader_controller.dart';
import 'translation_page_view.dart';

/// Écran de lecture : liste verticale des pages + calques de traduction.
class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    super.key,
    required this.path,
    required this.controller,
  });

  final String path;
  final ReaderController controller;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  bool _attached = false;

  String get _fileName {
    final segments = Uri.file(widget.path).pathSegments;
    return segments.isNotEmpty ? segments.last : 'Document';
  }

  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  Future<void> _openSettings() async {
    final updated = await Navigator.of(context).push<ReaderSettings>(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(settings: widget.controller.settings),
      ),
    );
    if (updated != null) {
      await widget.controller.updateSettings(updated);
      await SettingsStore.save(updated);
    }
  }

  Future<void> _translateAll(ReaderController controller) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await controller.translateWholeDocument();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Traduction impossible : $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: widget.controller,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_fileName, overflow: TextOverflow.ellipsis),
          actions: [
            Consumer<ReaderController>(
              builder: (context, controller, _) {
                final isTranslated =
                    controller.settings.mode == ReadingMode.translated;
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${controller.settings.sourceBcp.toUpperCase()} → '
                      '${controller.settings.targetBcp.toUpperCase()}',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    IconButton(
                      tooltip: isTranslated
                          ? 'Revenir au texte original'
                          : 'Afficher la traduction',
                      icon: Icon(
                        isTranslated ? Icons.menu_book : Icons.translate,
                      ),
                      onPressed: () => controller.updateSettings(
                        controller.settings.copyWith(
                          mode: isTranslated
                              ? ReadingMode.original
                              : ReadingMode.translated,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Traduire tout le document',
                      icon: const Icon(Icons.done_all),
                      onPressed: () => _translateAll(controller),
                    ),
                    IconButton(
                      tooltip: 'Réglages',
                      icon: const Icon(Icons.settings_outlined),
                      onPressed: _openSettings,
                    ),
                  ],
                );
              },
            ),
          ],
        ),
        body: PdfDocumentViewBuilder.file(
          widget.path,
          builder: (context, document) {
            if (document == null) {
              return const Center(child: CircularProgressIndicator());
            }
            if (!_attached) {
              _attached = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                widget.controller.attachDocument(document);
              });
            }
            return ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: document.pages.length,
              itemBuilder: (context, index) => TranslationPageView(
                key: ValueKey('page-${index + 1}'),
                document: document,
                pageNumber: index + 1,
              ),
            );
          },
        ),
      ),
    );
  }
}
