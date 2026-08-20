import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';

import '../models/text_block.dart';

/// Style visuel échantillonné d'un bloc.
class BlockStyle {
  const BlockStyle({
    required this.textColor,
    required this.backgroundColor,
    required this.bold,
  });

  final int textColor; // ARGB
  final int backgroundColor; // ARGB
  final bool bold;
}

class _CropStats {
  const _CropStats(this.textColor, this.backgroundColor, this.darkRatio);
  final int textColor;
  final int backgroundColor;
  final double darkRatio;
}

/// Analyse le rendu bitmap d'une page pour restituer le style visuel de
/// chaque bloc : couleur du texte, couleur de fond, graisse.
///
/// PDFium (via pdfrx) n'expose pas les attributs de police au niveau Dart ;
/// on échantillonne donc les pixels du bloc :
/// - pixels sombres → couleur moyenne du texte ;
/// - pixels clairs → couleur moyenne du fond ;
/// - densité d'encre relative à la médiane de la page → gras.
class StyleExtractor {
  static const double _dpi = 150.0;

  /// Rend la page en bitmap (~150 dpi) pour analyse.
  static Future<img.Image?> renderForAnalysis(PdfPage page) async {
    const scale = _dpi / 72.0;
    final rendered = await page.render(
      width: (page.width * scale).round(),
      height: (page.height * scale).round(),
    );
    if (rendered == null) return null;
    final image = rendered.createImageNF();
    rendered.dispose();
    return image;
  }

  /// Calcule le style de chaque bloc dans [blocks] à partir du rendu.
  static List<BlockStyle> analyze(
    img.Image image,
    List<TextBlock> blocks, {
    required double pageWidthPt,
    required double pageHeightPt,
  }) {
    final scale = image.width / pageWidthPt;
    final stats = [
      for (final block in blocks)
        _stats(image, block, scale, pageHeightPt),
    ];

    final ratios = stats.map((s) => s.darkRatio).toList()..sort();
    final median = ratios.isEmpty ? 0.0 : ratios[ratios.length ~/ 2];

    return [
      for (final s in stats)
        BlockStyle(
          textColor: s.textColor,
          backgroundColor: s.backgroundColor,
          bold: median > 0 && s.darkRatio > median * 1.5,
        ),
    ];
  }

  static _CropStats _stats(
    img.Image image,
    TextBlock block,
    double scale,
    double pageHeightPt,
  ) {
    final x0 = (block.left * scale).floor().clamp(0, image.width - 1);
    final x1 = (block.right * scale).ceil().clamp(x0 + 1, image.width);
    final y0 = ((pageHeightPt - block.top) * scale).floor().clamp(0, image.height - 1);
    final y1 = ((pageHeightPt - block.bottom) * scale).ceil().clamp(y0 + 1, image.height);

    var darkCount = 0;
    var lightCount = 0;
    var total = 0;
    var dr = 0, dg = 0, db = 0;
    var lr = 0, lg = 0, lb = 0;

    for (var y = y0; y < y1; y += 2) {
      for (var x = x0; x < x1; x += 2) {
        final p = image.getPixel(x, y);
        final r = p.r.toInt();
        final g = p.g.toInt();
        final b = p.b.toInt();
        final luminance = 0.299 * r + 0.587 * g + 0.114 * b;
        total++;
        if (luminance < 128) {
          darkCount++;
          dr += r;
          dg += g;
          db += b;
        } else {
          lightCount++;
          lr += r;
          lg += g;
          lb += b;
        }
      }
    }

    return _CropStats(
      darkCount > 0
          ? _argb(dr ~/ darkCount, dg ~/ darkCount, db ~/ darkCount)
          : 0xDE1A1A1A,
      lightCount > 0
          ? _argb(lr ~/ lightCount, lg ~/ lightCount, lb ~/ lightCount)
          : 0xFFFFFFFF,
      total == 0 ? 0.0 : darkCount / total,
    );
  }

  static int _argb(int r, int g, int b) =>
      0xFF000000 | ((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF);
}
