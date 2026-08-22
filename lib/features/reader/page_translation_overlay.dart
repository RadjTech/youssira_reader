import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:provider/provider.dart';

import '../../core/models/reader_settings.dart';
import '../../core/models/text_block.dart';
import '../../core/services/monetization/limits_service.dart';
import '../../core/services/pdf/block_layout.dart';
import '../monetization/limit_dialog.dart';
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

    final blocks = controller.blocksForPage(widget.page.pageNumber);
    final pageW = widget.page.width;
    final margins = BlockLayout.pageMargins(blocks, pageW);

    for (final block in blocks) {
      final progress = controller.progressFor(block.id);
      if (progress == null ||
          progress.state != BlockState.done ||
          progress.translatedText == null) {
        continue;
      }

      // Largeur étendue jusqu'aux marges/obstacles ; titres centrés en
      // pleine largeur utile (voir BlockLayout).
      final layout = BlockLayout.forBlock(
        block,
        pageWidth: pageW,
        leftMargin: margins.left,
        rightMargin: margins.right,
        allBlocks: blocks,
      );

      // Repère PDF (origine bas-gauche) → repère du viewer (haut-gauche),
      // relatif au coin haut-gauche de la page.
      final left = layout.left * scale;
      final top = (widget.page.height - block.top) * scale;
      final width = layout.width * scale;

      // Police : 100 % de la taille apparente de l'original (choix
      // utilisateur) — jamais plus grande, pour éviter tout chevauchement.
      final originalSize = block.fontSizeHint * scale;
      final fontSize = originalSize;

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
            italic: block.italic,
            family: block.family,
            uniformBackground: block.uniformBackground,
            patchHeight: block.height * scale,
            textAlign: layout.centered ? TextAlign.center : TextAlign.left,
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
        onPressed:
            controller.busy ? null : () => _onTranslatePressed(controller),
        icon: const Icon(Icons.translate),
        label: Text('Traduire la page $pageNumber'),
      );
    }

    return Positioned.fill(child: Center(child: content));
  }

  /// Bouton « Traduire la page » : en cas de quota gratuit atteint, ouvre
  /// le dialogue pub récompensée / Pro, puis réessaie si débloqué.
  Future<void> _onTranslatePressed(ReaderController controller) async {
    final messenger = ScaffoldMessenger.of(context);
    final pageNumber = widget.page.pageNumber;
    try {
      await controller.translatePage(pageNumber);
    } on QuotaExceededException {
      if (!mounted) return;
      final unlocked = await LimitDialog.show(context, 'pages');
      if (unlocked && mounted) {
        try {
          await controller.translatePage(pageNumber);
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
    required this.italic,
    required this.family,
    required this.uniformBackground,
    required this.patchHeight,
    required this.textAlign,
  });

  final String original;
  final String translated;
  final double fontSize;
  final double padding;
  final double opacity;
  final int textColor;
  final int backgroundColor;
  final bool bold;
  final bool italic;

  /// Famille de police d'origine : le calque utilise une police visuellement
  /// proche (Noto Serif pour les serif, Noto Sans Mono pour les monospace,
  /// police système sinon).
  final TextFamily family;
  final bool uniformBackground;

  String? get _fontFamilyName {
    switch (family) {
      case TextFamily.serif:
        return 'NotoSerif';
      case TextFamily.mono:
        return 'NotoSansMono';
      case TextFamily.sans:
        return null; // police système (Roboto) ≈ sans-serif
    }
  }

  /// Hauteur du patch de fond = hauteur de la boîte ORIGINALE. Le texte
  /// traduit peut déborder en dessous SANS fond, pour ne jamais effacer
  /// les éléments de l'original (traits, filigranes…) situés sous le bloc.
  final double patchHeight;
  final TextAlign textAlign;

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
    final text = Padding(
      padding: EdgeInsets.symmetric(horizontal: padding),
      child: Text(
        translated,
        textAlign: textAlign,
        textScaler: TextScaler.noScaling,
        style: TextStyle(
          fontFamily: _fontFamilyName,
          fontSize: fontSize,
          height: 1.2,
          color: Color(color),
          fontWeight: bold ? FontWeight.w700 : FontWeight.normal,
          fontStyle: italic ? FontStyle.italic : FontStyle.normal,
          shadows: uniformBackground ? null : _halo(color),
        ),
      ),
    );

    return GestureDetector(
      onTap: () => _showOriginal(context),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Le patch de fond est LIMITÉ à la boîte originale : jamais
          // effacer traits, logos ou filigranes situés sous le bloc.
          // Fond complexe → aucun rectangle : le PDF n'est pas dégradé.
          if (uniformBackground)
            Positioned(
              left: 0,
              top: 0,
              right: 0,
              height: patchHeight,
              child: Container(
                color: Color.fromRGBO(r, g, b, opacity.clamp(0.0, 1.0)),
              ),
            ),
          text,
        ],
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
