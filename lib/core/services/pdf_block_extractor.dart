import 'package:pdfrx/pdfrx.dart';

import '../models/text_block.dart';
import 'ocr_service.dart';
import 'style_extractor.dart';

/// Extrait les blocs de texte d'une page PDF avec leurs coordonnées ET leur
/// style visuel (couleurs, graisse).
///
/// Pipeline :
/// 1. `loadStructuredText()` (PDFium via pdfrx) → fragments avec bounding
///    boxes ;
/// 2. regroupement des fragments en lignes ;
/// 3. analyse bitmap ([StyleExtractor]) pour les couleurs / la graisse ;
/// 4. si la page ne contient aucun texte natif (page scannée), fallback OCR.
class PdfBlockExtractor {
  PdfBlockExtractor({OcrService? ocrService}) : _ocr = ocrService ?? OcrService();

  final OcrService _ocr;

  Future<List<TextBlock>> extractPage(PdfDocument document, int pageNumber) async {
    final page = document.pages[pageNumber - 1];
    final pageText = await page.loadStructuredText();

    final blocks = _groupFragmentsIntoLines(pageText);
    if (blocks.isEmpty) {
      return _ocr.recognizePage(page);
    }
    return _withStyles(page, blocks);
  }

  /// Échantillonne le style visuel de chaque bloc sur le rendu bitmap.
  Future<List<TextBlock>> _withStyles(PdfPage page, List<TextBlock> blocks) async {
    final image = await StyleExtractor.renderForAnalysis(page);
    if (image == null) return blocks;

    final styles = StyleExtractor.analyze(
      image,
      blocks,
      pageWidthPt: page.width,
      pageHeightPt: page.height,
    );

    return [
      for (var i = 0; i < blocks.length; i++)
        blocks[i].copyWithStyle(
          textColor: styles[i].textColor,
          backgroundColor: styles[i].backgroundColor,
          bold: styles[i].bold,
          uniformBackground: styles[i].uniformBackground,
        ),
    ];
  }

  /// Regroupe les fragments PDFium en lignes lisibles.
  ///
  /// Les fragments arrivent dans un ordre arbitraire : on trie de haut en bas
  /// puis de gauche à droite, et on fusionne les fragments dont les centres
  /// verticaux sont proches (tolérance = 60% de la hauteur du fragment).
  List<TextBlock> _groupFragmentsIntoLines(PdfPageText pageText) {
    final fragments = pageText.fragments
        .where((f) => f.text.trim().isNotEmpty && f.bounds.isNotEmpty)
        .toList();
    if (fragments.isEmpty) return const [];

    fragments.sort((a, b) {
      final dy = b.bounds.top.compareTo(a.bounds.top); // haut → bas
      return dy != 0 ? dy : a.bounds.left.compareTo(b.bounds.left);
    });

    final lines = <List<PdfPageTextFragment>>[];
    for (final fragment in fragments) {
      final centerY = (fragment.bounds.top + fragment.bounds.bottom) / 2;
      List<PdfPageTextFragment>? currentLine;

      if (lines.isNotEmpty) {
        final lastLine = lines.last;
        final lastCenter =
            (lastLine.first.bounds.top + lastLine.first.bounds.bottom) / 2;
        final tolerance = 0.6 * fragment.bounds.height;
        if ((centerY - lastCenter).abs() <= tolerance) {
          currentLine = lastLine;
        }
      }

      if (currentLine != null) {
        currentLine.add(fragment);
      } else {
        lines.add([fragment]);
      }
    }

    return [
      for (final line in lines) _mergeLine(line, pageText.pageNumber),
    ];
  }

  /// Fusionne les fragments d'une même ligne en un seul [TextBlock].
  TextBlock _mergeLine(List<PdfPageTextFragment> fragments, int pageNumber) {
    fragments.sort((a, b) => a.bounds.left.compareTo(b.bounds.left));

    final buffer = StringBuffer();
    PdfRect? merged;
    double maxLineHeight = 0;

    for (final fragment in fragments) {
      if (buffer.isNotEmpty) buffer.write(' ');
      buffer.write(fragment.text.trim());
      merged = merged == null ? fragment.bounds : merged.merge(fragment.bounds);
      if (fragment.bounds.height > maxLineHeight) {
        maxLineHeight = fragment.bounds.height;
      }
    }

    final text = buffer.toString().trim();
    final bounds = merged!;

    return TextBlock(
      id: TextBlock.computeId(text),
      pageNumber: pageNumber,
      text: text,
      left: bounds.left,
      top: bounds.top,
      right: bounds.right,
      bottom: bounds.bottom,
      source: BlockSource.native,
      fontSizeHint: maxLineHeight,
    );
  }
}
