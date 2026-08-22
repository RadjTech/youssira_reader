import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:provider/provider.dart';

import '../../core/app_services.dart';
import '../../core/models/reader_settings.dart';
import '../../core/services/monetization/limits_service.dart';
import '../../core/services/pdf_export_service.dart';
import '../assistant/assistant_screen.dart';
import '../monetization/limit_dialog.dart';
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
      widget.controller.attachDocument(document, widget.path);
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
    } on QuotaExceededException {
      if (!mounted) return;
      final unlocked = await LimitDialog.show(context, 'pages');
      if (unlocked && mounted) {
        try {
          await controller.translateWholeDocument();
        } catch (e) {
          messenger.showSnackBar(
            SnackBar(content: Text('Traduction impossible : $e')),
          );
        }
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Traduction impossible : $e')),
      );
    }
  }

  /// Export du document traduit : choix du format, traduction complète si
  /// nécessaire, puis génération avec barre de progression.
  Future<void> _exportPdf(ReaderController controller) async {
    final messenger = ScaffoldMessenger.of(context);

    if (!PdfExportService.supportsTarget(controller.effectivePair.to)) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Export PDF indisponible pour cette langue cible pour le '
            'moment (polices latines uniquement).',
          ),
        ),
      );
      return;
    }

    final imageBased = await showDialog<bool>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Format du PDF traduit'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(true),
            child: const ListTile(
              leading: Icon(Icons.image_outlined),
              title: Text('Fidèle (pages en image + traduction)'),
              subtitle: Text(
                'Mise en page, images et logos conservés. Fichier plus lourd.',
              ),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(false),
            child: const ListTile(
              leading: Icon(Icons.text_snippet_outlined),
              title: Text('Léger (texte seul)'),
              subtitle: Text(
                "Blocs traduits repositionnés comme l'original. "
                'Fichier très léger, sans images.',
              ),
            ),
          ),
        ],
      ),
    );
    if (imageBased == null) return;
    if (!mounted) return;

    final allTranslated = [
      for (var i = 1; i <= controller.pageCount; i++)
        controller.isPageTranslated(i),
    ].every((e) => e);
    if (!allTranslated) {
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text("Traduire d'abord ?"),
          content: const Text(
            "Le document n'est pas entièrement traduit. Traduire tout le "
            "document avant l'export ?",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Traduire puis exporter'),
            ),
          ],
        ),
      );
      if (go != true) return;
      await controller.translateWholeDocument();
      if (!mounted) return;
    }

    // Quota gratuit d'exports (Pro = illimité) : dialogue pub/Pro si atteint.
    if (!AppServices.instance.entitlements.isPro) {
      try {
        AppServices.instance.limits.tryConsumeExport();
      } on QuotaExceededException {
        if (!mounted) return;
        final unlocked = await LimitDialog.show(context, 'exports');
        if (!unlocked) return;
      }
    }

    if (!mounted) return;
    final progress = ValueNotifier<double>(0);
    final label = ValueNotifier<String>('Export…');
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => ValueListenableBuilder<double>(
        valueListenable: progress,
        builder: (context, value, _) => ValueListenableBuilder<String>(
          valueListenable: label,
          builder: (context, text, _) => AlertDialog(
            title: const Text('Export du PDF traduit'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: value),
                const SizedBox(height: 10),
                Text(text),
              ],
            ),
          ),
        ),
      ),
    ));

    try {
      final path = await PdfExportService.exportTranslatedPdf(
        sourcePath: widget.path,
        controller: controller,
        imageBased: imageBased,
        onProgress: (p, l) {
          if (p != null) progress.value = p;
          label.value = l;
        },
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      // Interstitiel après un export réussi (jamais pour les Pro,
      // jamais bloquant : hors-ligne, rien ne s'affiche).
      if (!AppServices.instance.entitlements.isPro) {
        await AppServices.instance.ads.showInterstitial();
      }
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            path == null
                ? 'Export annulé.'
                : 'PDF traduit enregistré :\n$path',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(content: Text('Export impossible : $e')),
      );
    } finally {
      progress.dispose();
      label.dispose();
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
                                : controller.settings.mode == ReadingMode.document
                                    ? Icons.description_outlined
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
                        PopupMenuItem(
                          value: ReadingMode.document,
                          child: Text('Document traduit (Xodo)'),
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
                      tooltip: 'Assistant du document (chat local)',
                      icon: const Icon(Icons.smart_toy_outlined),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              AssistantScreen(controller: controller),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Exporter le PDF traduit',
                      icon: const Icon(Icons.picture_as_pdf_outlined),
                      onPressed:
                          controller.busy ? null : () => _exportPdf(controller),
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
            Widget main;
            // Mode « document traduit » (Xodo) : PDF recomposé rouvert dans
            // le viewer. On attache d'abord le document original (blocs).
            if (controller.settings.mode == ReadingMode.document) {
              main = PdfDocumentViewBuilder.file(
                widget.path,
                builder: (context, document) {
                  if (document == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  _attachOnce(document);
                  return _buildDocumentMode(controller);
                },
              );
            } else if (controller.settings.mode == ReadingMode.reflow) {
              // Mode lecture : document retypographié comme un ebook.
              main = PdfDocumentViewBuilder.file(
                widget.path,
                builder: (context, document) {
                  if (document == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  _attachOnce(document);
                  return ReflowReaderView(document: document);
                },
              );
            } else {
              main = _buildViewer();
            }
            return Stack(
              children: [
                main,
                if (controller.docRunning)
                  _DocProgressBanner(controller: controller),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Mode « document traduit » : PDF recomposé (image + texte reflowé)
  /// rouvert comme document à part entière ; avant génération, écran
  /// d'accueil avec bouton ; après nouvelles traductions, bouton régénérer.
  Widget _buildDocumentMode(ReaderController controller) {
    final path = controller.translatedDocPath;
    if (path == null) {
      return Center(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.auto_awesome, size: 44),
                const SizedBox(height: 12),
                Text(
                  'Document traduit',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Le document est recomposé : pages originales\n'
                  'conservées, texte traduit reflowé par-dessus\n'
                  'avec un vrai moteur de mise en page.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: controller.busy || controller.generatingDoc
                      ? null
                      : () => controller.openTranslatedDocument(),
                  icon: const Icon(Icons.translate),
                  label: const Text('Générer le document traduit'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Stack(
      children: [
        PdfViewer.file(path),
        if (controller.translatedDocStale && !controller.generatingDoc)
          Positioned(
            top: 8,
            left: 8,
            right: 8,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text('Nouvelles traductions disponibles.'),
                    ),
                    TextButton(
                      onPressed: controller.busy
                          ? null
                          : () => controller.openTranslatedDocument(),
                      child: const Text('Régénérer'),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
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

/// Bannière de progression « Traduire tout le document » : phase d'analyse
/// puis pourcentage et compteur de blocs, avec bouton d'annulation.
class _DocProgressBanner extends StatelessWidget {
  const _DocProgressBanner({required this.controller});

  final ReaderController controller;

  @override
  Widget build(BuildContext context) {
    final analyzing = controller.docAnalyzing;
    final progress = controller.docProgress;
    return Positioned(
      left: 8,
      right: 8,
      bottom: 8,
      child: Card(
        elevation: 6,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      analyzing
                          ? 'Analyse du document…'
                          : 'Traduction du document…',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Annuler',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close),
                    onPressed: controller.cancelDocumentTranslation,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: analyzing ? null : progress),
              if (!analyzing) ...[
                const SizedBox(height: 6),
                Text(
                  '${(progress * 100).toStringAsFixed(0)} % — '
                  '${controller.docDoneBlocks} / '
                  '${controller.docTotalBlocks} blocs',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
