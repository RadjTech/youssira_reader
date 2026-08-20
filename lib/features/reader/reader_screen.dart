import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:provider/provider.dart';

import '../../core/models/reader_settings.dart';
import '../settings/settings_screen.dart';
import 'page_translation_overlay.dart';
import 'reader_controller.dart';
import 'reflow_reader_view.dart';

/// Écran de lecture : viewer PDF natif (zoom/pinch/pan intégrés) + calques de
/// traduction superposés via `pageOverlaysBuilder`, donc solidaires du zoom.
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

  void _attachOnce(PdfDocument document) {
    if (_attached) return;
    _attached = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.attachDocument(document);
    });
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
                final pair = controller.effectivePair;
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${pair.from.toUpperCase()} → ${pair.to.toUpperCase()}',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    PopupMenuButton<ReadingMode>(
                      tooltip: 'Mode de lecture',
                      icon: Icon(
                        controller.settings.mode == ReadingMode.translated
                            ? Icons.translate
                            : controller.settings.mode == ReadingMode.reflow
                                ? Icons.article
                                : Icons.menu_book,
                      ),
                      onSelected: (mode) => controller.updateSettings(
                        controller.settings.copyWith(mode: mode),
                      ),
                      itemBuilder: (context) => const [
                        PopupMenuItem(
                          value: ReadingMode.original,
                          child: Text('Document original'),
                        ),
                        PopupMenuItem(
                          value: ReadingMode.translated,
                          child: Text('Traduction superposée'),
                        ),
                        PopupMenuItem(
                          value: ReadingMode.reflow,
                          child: Text('Mode lecture (ebook)'),
                        ),
                      ],
                    ),
                    IconButton(
                      tooltip: 'Traduire tout le document',
                      icon: controller.busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.done_all),
                      onPressed:
                          controller.busy ? null : () => _translateAll(controller),
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
        body: Consumer<ReaderController>(
          builder: (context, controller, _) {
            // Mode lecture : document retypographié comme un ebook.
            if (controller.settings.mode == ReadingMode.reflow) {
              return PdfDocumentViewBuilder.file(
                widget.path,
                builder: (context, document) {
                  if (document == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  _attachOnce(document);
                  return ReflowReaderView(document: document);
                },
              );
            }
            return _buildViewer();
          },
        ),
      ),
    );
  }

  /// Viewer PDF natif (zoom/pinch/pan) + calques solidaires du zoom.
  Widget _buildViewer() {
    return PdfViewer.file(
      widget.path,
      params: PdfViewerParams(
        // Les calques de traduction vivent DANS le viewer : ils suivent
        // naturellement le zoom et le pan.
        pageOverlaysBuilder: (context, pageRect, page) {
          _attachOnce(page.document);
          return [
            PageTranslationOverlay(page: page, pageRect: pageRect),
          ];
        },
        // Signal visuel pendant le chargement initial du document.
        loadingBannerBuilder: (context, bytesDownloaded, totalBytes) =>
            const Center(
          child: Card(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('Ouverture du document…'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
