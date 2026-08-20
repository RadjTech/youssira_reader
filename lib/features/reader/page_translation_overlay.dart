import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:provider/provider.dart';

import '../../core/models/reader_settings.dart';
import 'reader_controller.dart';

/// Calques de traduction d'une page, rendus DANS le viewer pdfrx via
/// `pageOverlaysBuilder`. Les coordonnées sont relatives à la page telle
/// qu'elle est dessinée ([pageRect]) : tout suit donc le zoom et le pan.
class PageTranslationOverlay extends StatefulWidget {
  const PageTranslationOverlay({
    super.key,
    required this.page,
    required this.pageRect,
  });

  final PdfPage page;
  final Rect pageRect;

  @override
  State<PageTranslationOverlay> createState() => _PageTranslationOverlayState();
}

class _PageTranslationOverlayState extends State<PageTranslationOverlay> {
  @override
  void initState() {
    super.initState();
    // Extraction paresseuse des blocs quand la page devient visible.
    Future.microtask(() {
      if (!mounted) return;
      context
          .read<ReaderController>()
          .ensureBlocks(widget.page.pageNumber);
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ReaderController>();
    if (controller.settings.mode != ReadingMode.translated) {
      return const SizedBox.shrink();
    }

    // Échelle points PDF → pixels du viewer (varie avec le zoom).
    final scale = widget.pageRect.width / widget.page.width;
    final children = <Widget>[
      ..._buildOverlays(controller, scale),
      if (!controller.isPageTranslated(widget.page.pageNumber))
        _buildPromptOrProgress(controller),
    ];
    // On gère notre propre Stack : le widget retourné remplit le rectangle de
    // la page tel qu'il est dessiné dans le viewer.
    return SizedBox.expand(child: Stack(children: children));
  }

  List<Widget> _buildOverlays(ReaderController controller, double scale) {
    final overlays = <Widget>[];

    for (final block in controller.blocksForPage(widget.page.pageNumber)) {
      final progress = controller.progressFor(block.id);
      if (progress == null ||
          progress.state != BlockState.done ||
          progress.translatedText == null) {
        continue;
      }

      // Repère PDF (origine bas-gauche) → repère du viewer (haut-gauche),
      // relatif au coin haut-gauche de la page.
      final left = block.left * scale;
      final top = (widget.page.height - block.top) * scale;
      final width = block.width * scale;

      overlays.add(
        Positioned(
          left: left,
          top: top,
          width: width,
          // Pas de hauteur fixée : le texte traduit s'enroule et la boîte
          // grandit vers le bas si besoin (traductions plus longues que
          // l'original) au lieu de rétrécir la police.
          child: _TranslationOverlayBox(
            original: block.text,
            translated: progress.translatedText!,
            fontSize: math.max(block.fontSizeHint * scale * 0.8, 9),
            padding: 2 * scale,
            opacity: controller.settings.overlayOpacity,
          ),
        ),
      );
    }
    return overlays;
  }

  Widget _buildPromptOrProgress(ReaderController controller) {
    return Positioned.fill(
      child: Center(
        child: controller.preparing
            ? const Card(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 12),
                      Text('Préparation des modèles de langue…'),
                      Text(
                        '~30 Mo par langue, une seule fois',
                        style: TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              )
            : FilledButton.icon(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  try {
                    await controller.translatePage(widget.page.pageNumber);
                  } catch (e) {
                    messenger.showSnackBar(
                      SnackBar(content: Text('Traduction impossible : $e')),
                    );
                  }
                },
                icon: const Icon(Icons.translate),
                label: Text('Traduire la page ${widget.page.pageNumber}'),
              ),
      ),
    );
  }
}

/// Le calque d'un bloc : fond blanc opaque + texte traduit enroulé, ajusté au
/// rectangle du bloc d'origine. Tap = afficher le texte original.
class _TranslationOverlayBox extends StatelessWidget {
  const _TranslationOverlayBox({
    required this.original,
    required this.translated,
    required this.fontSize,
    required this.padding,
    required this.opacity,
  });

  final String original;
  final String translated;
  final double fontSize;
  final double padding;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showOriginal(context),
      child: Container(
        color: Color.fromRGBO(255, 255, 255, opacity.clamp(0.0, 1.0)),
        padding: EdgeInsets.symmetric(horizontal: padding),
        child: Text(
          translated,
          style: TextStyle(
            fontSize: fontSize,
            height: 1.2,
            color: const Color(0xDE1A1A1A),
          ),
        ),
      ),
    );
  }

  void _showOriginal(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Texte original'),
        content: SingleChildScrollView(child: SelectableText(original)),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}
