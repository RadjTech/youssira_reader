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

      // Police : ~85 % de la taille apparente de l'original pour la
      // lisibilité, mais JAMAIS plus grande que l'original (sinon les
      // lignes débordent et chevauchent la suite du document). Plancher
      // 7 px, lui aussi plafonné à l'original.
      final originalSize = block.fontSizeHint * scale;
      final fontSize = math.min(
        originalSize,
        math.max(originalSize * 0.85, math.min(7.0, originalSize)),
      );

      overlays.add(
        Positioned(
          left: left,
          top: top,
          width: width,
          // Pas de hauteur fixée (recette de la toute première version,
          // rendu « Google Lens ») : le texte traduit s'enroule à taille
          // LISIBLE et la boîte grandit vers le bas si la traduction est
          // plus longue que l'original — jamais de police microscopique.
          child: _TranslationOverlayBox(
            original: block.text,
            translated: progress.translatedText!,
            fontSize: fontSize,
            padding: 2 * scale,
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

/// Le calque d'un bloc, recette de la toute première version (rendu
/// « Google Lens ») : texte traduit LISIBLE et enroulé sur un patch qui
/// recouvre l'original ; la boîte grandit vers le bas si besoin.
/// Améliorations conservées sans changer le rendu sur page blanche :
/// - patch = couleur de fond échantillonnée (blanc sur page blanche) au lieu
///   de blanc forcé, donc invisible sur la page ;
/// - fond COMPLEXE (image, capture, dégradé) → AUCUN rectangle, texte avec
///   halo contrasté pour ne pas dégrader le PDF ;
/// - garde de contraste texte/fond (jamais de texte invisible) ;
/// - graisse du texte d'origine respectée.
/// Tap = texte original.
class _TranslationOverlayBox extends StatelessWidget {
  const _TranslationOverlayBox({
    required this.original,
    required this.translated,
    required this.fontSize,
    required this.padding,
    required this.opacity,
    required this.textColor,
    required this.backgroundColor,
    required this.bold,
    required this.uniformBackground,
  });

  final String original;
  final String translated;
  final double fontSize;
  final double padding;
  final double opacity;
  final int textColor;
  final int backgroundColor;
  final bool bold;
  final bool uniformBackground;

  static double _lum(int c) {
    final r = (c >> 16) & 0xFF;
    final g = (c >> 8) & 0xFF;
    final b = c & 0xFF;
    return (0.299 * r + 0.587 * g + 0.114 * b) / 255;
  }

  @override
  Widget build(BuildContext context) {
    final bgLum = _lum(backgroundColor);
    // Garde de contraste : jamais de texte fondu dans le fond.
    var color = textColor;
    if ((_lum(color) - bgLum).abs() < 0.3) {
      color = bgLum > 0.5 ? 0xFF1A1A1A : 0xFFFFFFFF;
    }

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
        padding: EdgeInsets.symmetric(horizontal: padding),
        child: Text(
          translated,
          textAlign: TextAlign.left,
          textScaler: TextScaler.noScaling,
          style: TextStyle(
            fontSize: fontSize,
            height: 1.2,
            color: Color(color),
            fontWeight: bold ? FontWeight.w700 : FontWeight.normal,
            shadows: uniformBackground ? null : _halo(color),
          ),
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
