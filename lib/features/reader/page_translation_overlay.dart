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
      final fontSize = math.max(block.fontSizeHint * scale, 6.0);

      overlays.add(
        Positioned(
          left: left,
          top: top,
          width: width,
          height: height,
          child: _TranslationOverlayBox(
            original: block.text,
            translated: progress.translatedText!,
            fontSize: fontSize,
            boxWidth: width,
            boxHeight: height,
            opacity: controller.settings.overlayOpacity,
            textColor: block.textColor,
            backgroundColor: block.backgroundColor,
            bold: block.bold,
            uniformBackground: block.uniformBackground,
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

/// Le calque d'un bloc, style « Google Lens » :
/// - fond UNIFORME (page blanche, encadré uni) → patch opaque de la couleur
///   de fond échantillonnée : l'original est recouvert, invisible ;
/// - fond COMPLEXE (image, capture, dégradé) → AUCUN rectangle, le texte est
///   posé avec un halo contrasté pour rester lisible sans dégrader le PDF ;
/// - texte = couleur du texte d'origine, avec garde de contraste (jamais de
///   texte invisible sur fond proche) ; graisse détectée.
/// Adaptation au débordement : le corps est réduit par paliers (plancher
/// 7 px), le nombre de lignes augmente et l'interligne se resserre jusqu'à
/// ce que TOUTE la traduction tienne STRICTEMENT dans le rectangle
/// d'origine ; en dernier recours seulement, troncature avec « … ».
/// Tap = texte original.
class _TranslationOverlayBox extends StatelessWidget {
  const _TranslationOverlayBox({
    required this.original,
    required this.translated,
    required this.fontSize,
    required this.boxWidth,
    required this.boxHeight,
    required this.opacity,
    required this.textColor,
    required this.backgroundColor,
    required this.bold,
    required this.uniformBackground,
  });

  final String original;
  final String translated;
  final double fontSize;
  final double boxWidth;
  final double boxHeight;
  final double opacity;
  final int textColor;
  final int backgroundColor;
  final bool bold;
  final bool uniformBackground;

  static const double _minFontSize = 7.0;

  static double _lum(int c) {
    final r = (c >> 16) & 0xFF;
    final g = (c >> 8) & 0xFF;
    final b = c & 0xFF;
    return (0.299 * r + 0.587 * g + 0.114 * b) / 255;
  }

  TextStyle _style(double size, double lineHeight, Color color,
          {List<Shadow>? shadows}) =>
      TextStyle(
        fontSize: size,
        height: lineHeight,
        color: color,
        fontWeight: bold ? FontWeight.w700 : FontWeight.normal,
        shadows: shadows,
      );

  /// Plus grand corps ≤ [fontSize] pour lequel la traduction entière tient
  /// dans [boxWidth]×[boxHeight] ; à défaut, le plancher (la troncature est
  /// alors inévitable mais le rectangle reste respecté).
  ({double size, int maxLines, double lineHeight}) _autoFit() {
    double size = fontSize;
    while (true) {
      final lineHeight = size * (size >= fontSize ? 1.1 : 1.05);
      final maxLines = math.max(1, (boxHeight / lineHeight).floor());
      final painter = TextPainter(
        text: TextSpan(
          text: translated,
          // La couleur n'influence pas la mesure : noir arbitraire.
          style: _style(size, lineHeight, const Color(0xFF000000)),
        ),
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
        maxLines: maxLines,
      )..layout(maxWidth: boxWidth);
      if (!painter.didExceedMaxLines || size <= _minFontSize) {
        return (size: size, maxLines: maxLines, lineHeight: lineHeight);
      }
      size = math.max(_minFontSize, size * 0.85);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fit = _autoFit();
    final bgLum = _lum(backgroundColor);
    // Garde de contraste : jamais de texte fondu dans le fond.
    var color = textColor;
    if ((_lum(color) - bgLum).abs() < 0.3) {
      color = bgLum > 0.5 ? 0xFF111111 : 0xFFFFFFFF;
    }
    final style = uniformBackground
        ? _style(fit.size, fit.lineHeight, Color(color))
        : _style(fit.size, fit.lineHeight, Color(color),
            shadows: _halo(color));

    // Composantes RGB extraites directement de l'ARGB stocké (évite les
    // accès Color.red/green/blue dépréciés).
    final r = (backgroundColor >> 16) & 0xFF;
    final g = (backgroundColor >> 8) & 0xFF;
    final b = backgroundColor & 0xFF;
    return GestureDetector(
      onTap: () => _showOriginal(context),
      child: Container(
        // Fond complexe → aucun rectangle : le PDF n'est pas dégradé.
        color: uniformBackground
            ? Color.fromRGBO(r, g, b, opacity.clamp(0.0, 1.0))
            : null,
        alignment: Alignment.centerLeft,
        child: Text(
          translated,
          maxLines: fit.maxLines,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.left,
          textScaler: TextScaler.noScaling,
          style: style,
        ),
      ),
    );
  }

  /// Halo contrasté pour fond complexe : 4 ombres courtes autour des
  /// glyphes, couleur opposée au texte (lisibilité type Google Lens).
  List<Shadow> _halo(int color) {
    final halo = _lum(color) > 0.5
        ? const Color(0xCC000000)
        : const Color(0xCCFFFFFF);
    return [
      Shadow(offset: const Offset(-1, -1), blurRadius: 1, color: halo),
      Shadow(offset: const Offset(1, -1), blurRadius: 1, color: halo),
      Shadow(offset: const Offset(-1, 1), blurRadius: 1, color: halo),
      Shadow(offset: const Offset(1, 1), blurRadius: 1, color: halo),
    ];
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
