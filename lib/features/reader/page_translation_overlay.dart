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
      final height = block.height * scale;

      // Le calque reste STRICTEMENT dans le rectangle du bloc d'origine :
      // le document traduit garde exactement la silhouette de l'original.
      overlays.add(
        Positioned(
          left: left,
          top: top,
          width: width,
          height: height,
          child: _TranslationOverlayBox(
            original: block.text,
            translated: progress.translatedText!,
            fontSize: math.max(block.fontSizeHint * scale, 6),
            opacity: controller.settings.overlayOpacity,
            textColor: block.textColor,
            backgroundColor: block.backgroundColor,
            bold: block.bold,
          ),
        ),
      );
    }
    return overlays;
  }

  Widget _buildPromptOrProgress(ReaderController controller) {
    final pageNumber = widget.page.pageNumber;
    Widget content;

    if (controller.preparing) {
      // Phase de préparation UNIQUEMENT : téléchargement des modèles.
      content = const Card(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 12),
              Text('Téléchargement des modèles de langue…'),
              Text(
                '~30 Mo par langue, une seule fois',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      );
    } else if (controller.busy && controller.isTranslatingPage(pageNumber)) {
      // Traduction des blocs en cours : les calques arrivent au fil de l'eau.
      content = Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Text('Traduction de la page $pageNumber…'),
            ],
          ),
        ),
      );
    } else {
      content = FilledButton.icon(
        onPressed: controller.busy
            ? null
            : () async {
                final messenger = ScaffoldMessenger.of(context);
                try {
                  await controller.translatePage(pageNumber);
                } catch (e) {
                  messenger.showSnackBar(
                    SnackBar(content: Text('Traduction impossible : $e')),
                  );
                }
              },
        icon: const Icon(Icons.translate),
        label: Text('Traduire la page $pageNumber'),
      );
    }

    return Positioned.fill(child: Center(child: content));
  }
}

/// Le calque d'un bloc : fond = couleur de fond échantillonnée du bloc
/// d'origine, texte = couleur du texte d'origine, graisse détectée. Le tout
/// ajusté AU rectangle du bloc (FittedBox), sans jamais déborder.
/// Tap = texte original.
class _TranslationOverlayBox extends StatelessWidget {
  const _TranslationOverlayBox({
    required this.original,
    required this.translated,
    required this.fontSize,
    required this.opacity,
    required this.textColor,
    required this.backgroundColor,
    required this.bold,
  });

  final String original;
  final String translated;
  final double fontSize;
  final double opacity;
  final int textColor;
  final int backgroundColor;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    // Composantes RGB extraites directement de l'ARGB stocké (évite les
    // accès Color.red/green/blue dépréciés).
    final r = (backgroundColor >> 16) & 0xFF;
    final g = (backgroundColor >> 8) & 0xFF;
    final b = backgroundColor & 0xFF;
    return GestureDetector(
      onTap: () => _showOriginal(context),
      child: Container(
        color: Color.fromRGBO(r, g, b, opacity.clamp(0.0, 1.0)),
        alignment: Alignment.centerLeft,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            translated,
            maxLines: 6,
            textAlign: TextAlign.left,
            style: TextStyle(
              fontSize: fontSize,
              height: 1.1,
              color: Color(textColor),
              fontWeight: bold ? FontWeight.w700 : FontWeight.normal,
            ),
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
