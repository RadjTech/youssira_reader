import 'package:flutter/foundation.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/text_block.dart';
import 'ocr_service.dart';
import 'pdf/pdfium_styled_text.dart';
import 'style_extractor.dart';

/// Extrait les blocs de texte d'une page PDF avec leurs coordonnées ET leur
/// style visuel (couleurs, graisse).
///
/// Pipeline :
/// 1. `loadStructuredText()` (PDFium via pdfrx) → fragments avec bounding
///    boxes ;
/// 2. regroupement des fragments en lignes ;
/// 3. analyse bitmap ([StyleExtractor]) pour la couleur de fond ;
/// 4. style réel du texte (taille de police, graisse, couleur) lu
///    directement dans le PDF via l'API C de PDFium
///    ([PdfiumStyledText]) — remplace les heuristiques quand disponible ;
/// 5. si la page ne contient aucun texte natif (page scannée), fallback OCR.
class PdfBlockExtractor {
  PdfBlockExtractor({OcrService? ocrService}) : _ocr = ocrService ?? OcrService();

  final OcrService _ocr;

  /// [filePath] : chemin du PDF sur disque. Requis pour l'extraction du
  /// style réel via l'API C de PDFium ; si absent, on garde les
  /// heuristiques bitmap.
  Future<List<TextBlock>> extractPage(
    PdfDocument document,
    int pageNumber, {
    String? filePath,
  }) async {
    final page = document.pages[pageNumber - 1];
    final pageText = await page.loadStructuredText();

    final blocks = _groupFragmentsIntoLines(pageText);
    if (blocks.isEmpty) {
      return _ocr.recognizePage(page);
    }
    final styled = await _withStyles(page, blocks);
    if (filePath == null) return styled;
    // Le style réel (FFI) est un bonus : s'il échoue, on garde surtout les
    // blocs heuristiques — jamais d'échec d'extraction à cause de lui.
    try {
      final chars = PdfiumStyledText.extractPage(filePath, pageNumber - 1);
      return _withRealStyles(styled, chars);
    } catch (e) {
      debugPrint('Style PDFium ignoré (page $pageNumber) : $e');
      return styled;
    }
  }

  /// Remplace les heuristiques bitmap par les styles RÉELS du PDF
  /// (PDFium `FPDFText`) : taille de police, graisse et couleur exactes par
  /// caractère, agrégées par bloc (taille/couleur dominantes, graisse max).
  /// Un bloc sans caractère correspondant garde son style heuristique.
  List<TextBlock> _withRealStyles(
    List<TextBlock> blocks,
    List<PdfStyledChar> chars,
  ) {
    if (chars.isEmpty) return blocks;
    return [for (final block in blocks) _mergeRealStyle(block, chars)];
  }

  TextBlock _mergeRealStyle(TextBlock block, List<PdfStyledChar> chars) {
    final sizeCounts = <double, int>{};
    final colorCounts = <int, int>{};
    var maxWeight = -1;
    var matched = 0;

    for (final c in chars) {
      if (c.isWhitespace) continue;
      if (c.centerX < block.left ||
          c.centerX > block.right ||
          c.centerY < block.bottom ||
          c.centerY > block.top) {
        continue;
      }
      matched++;
      if (c.fontSize > 0) {
        // Arrondi au demi-point pour regrouper les tailles identiques.
        final key = (c.fontSize * 2).roundToDouble() / 2;
        sizeCounts[key] = (sizeCounts[key] ?? 0) + 1;
      }
      if (c.fontWeight > maxWeight) maxWeight = c.fontWeight;
      final rgb = c.colorRgb;
      if (rgb != null) {
        colorCounts[rgb] = (colorCounts[rgb] ?? 0) + 1;
      }
    }
    if (matched == 0) return block;

    double? dominantSize;
    var bestSizeCount = 0;
    sizeCounts.forEach((size, n) {
      if (n > bestSizeCount) {
        bestSizeCount = n;
        dominantSize = size;
      }
    });

    int? dominantColor;
    var bestColorCount = 0;
    colorCounts.forEach((rgb, n) {
      if (n > bestColorCount) {
        bestColorCount = n;
        dominantColor = rgb;
      }
    });

    final color = dominantColor;
    return block.withRealStyle(
      fontSize: dominantSize,
      textColor: color != null ? 0xFF000000 | color : null,
      // PDFium : 400 = normal, 700 = gras. -1 = inconnu → on garde
      // l'heuristique bitmap.
      bold: maxWeight > 0 ? maxWeight >= 550 : null,
    );
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
