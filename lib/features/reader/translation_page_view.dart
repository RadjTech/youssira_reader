import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:provider/provider.dart';

import '../../core/models/reader_settings.dart';
import '../../core/utils/coords.dart';
import 'reader_controller.dart';

/// Une page du document : rendu PDFium + calque de traduction superposé aux
/// coordonnées exactes des blocs de texte.
class TranslationPageView extends StatefulWidget {
  const TranslationPageView({
    super.key,
    required this.document,
    required this.pageNumber,
  });

  final PdfDocument document;
  final int pageNumber;

  @override
  State<TranslationPageView> createState() => _TranslationPageViewState();
}

class _TranslationPageViewState extends State<TranslationPageView> {
  @override
  void initState() {
    super.initState();
    // Extraction paresseuse des blocs quand la page apparaît.
    Future.microtask(() {
      if (!mounted) return;
      context.read<ReaderController>().ensureBlocks(widget.pageNumber);
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ReaderController>();
    final page = widget.document.pages[widget.pageNumber - 1];

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height =
            page.width == 0 ? width : page.height / page.width * width;

        return Container(
          width: width,
          height: height,
          margin: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: kElevationToShadow[2],
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              PdfPageView(
                document: widget.document,
                pageNumber: widget.pageNumber,
              ),
              if (controller.settings.mode == ReadingMode.translated) ...[
                ..._buildOverlays(controller, page, width, height),
                if (!controller.isPageTranslated(widget.pageNumber))
                  _buildTranslatePrompt(controller),
              ],
            ],
          ),
        );
      },
    );
  }

  /// Les calques de traduction : un Positioned par bloc traduit, converti du
  /// repère PDF vers le repère du widget.
  List<Widget> _buildOverlays(
    ReaderController controller,
    PdfPage page,
    double width,
    double height,
  ) {
    final scale = width / page.width;
    final overlays = <Widget>[];

    for (final block in controller.blocksForPage(widget.pageNumber)) {
      final progress = controller.progressFor(block.id);
      if (progress == null ||
          progress.state != BlockState.done ||
          progress.translatedText == null) {
        continue;
      }

      final rect = pdfRectToWidget(
        left: block.left,
        top: block.top,
        right: block.right,
        bottom: block.bottom,
        pageWidthPt: page.width,
        pageHeightPt: page.height,
        widgetWidth: width,
        widgetHeight: height,
      );

      overlays.add(
        Positioned.fromRect(
          rect: rect,
          child: _TranslationOverlayBox(
            original: block.text,
            translated: progress.translatedText!,
            fontSize: math.max(block.fontSizeHint * scale * 0.8, 2),
            opacity: controller.settings.overlayOpacity,
          ),
        ),
      );
    }
    return overlays;
  }

  /// Bouton flottant proposé sur une page pas encore traduite.
  Widget _buildTranslatePrompt(ReaderController controller) {
    return Positioned.fill(
      child: Center(
        child: FilledButton.icon(
          onPressed: () async {
            final messenger = ScaffoldMessenger.of(context);
            try {
              await controller.translatePage(widget.pageNumber);
            } catch (e) {
              messenger.showSnackBar(
                SnackBar(content: Text('Traduction impossible : $e')),
              );
            }
          },
          icon: const Icon(Icons.translate),
          label: Text('Traduire la page ${widget.pageNumber}'),
        ),
      ),
    );
  }
}

/// Le calque de traduction d'un bloc : fond blanc semi-opaque + texte traduit
/// ajusté au rectangle du bloc d'origine. Tap = afficher le texte original.
class _TranslationOverlayBox extends StatelessWidget {
  const _TranslationOverlayBox({
    required this.original,
    required this.translated,
    required this.fontSize,
    required this.opacity,
  });

  final String original;
  final String translated;
  final double fontSize;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showOriginal(context),
      child: Container(
        color: Color.fromRGBO(255, 255, 255, opacity.clamp(0.0, 1.0)),
        padding: const EdgeInsets.symmetric(horizontal: 1),
        alignment: Alignment.centerLeft,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            translated,
            maxLines: 5,
            style: TextStyle(
              fontSize: fontSize,
              height: 1.05,
              color: const Color(0xDD1A1A1A),
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
