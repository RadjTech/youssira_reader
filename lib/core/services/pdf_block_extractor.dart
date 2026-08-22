import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mupdf_extractor/mupdf_extractor.dart';
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

    final lines = _groupFragmentsIntoLines(pageText);
    if (lines.isEmpty) {
      return _ocr.recognizePage(page);
    }
    // MuPDF d'abord (si disponible) : ses spans police/taille RÉELS guident
    // la fusion en paragraphes (un libellé gras ou un titre plus gros ne
    // fusionne jamais avec le corps qui le suit), puis remplacent les
    // heuristiques de style. Échec → null → fusion purement géométrique.
    List<MupdfSpan>? mupdfSpans;
    if (filePath != null) {
      try {
        mupdfSpans = await MupdfStyledText.extractPage(
          filePath,
          pageNumber - 1,
        );
      } catch (e) {
        debugPrint('MuPDF ignoré (page $pageNumber) : $e');
      }
    }
    // Les lignes d'un même paragraphe sont regroupées AVANT traduction :
    // une phrase coupée sur plusieurs lignes est traduite d'un seul tenant
    // (plus de traductions coupées ni de trous entre les patchs).
    final blocks = _mergeLinesIntoParagraphs(lines, mupdfSpans);
    final styled = await _withStyles(page, blocks);
    if (filePath == null) return styled;
    var result = styled;
    // Le style réel (FFI) est un bonus : s'il échoue, on garde les blocs
    // heuristiques — jamais d'échec d'extraction à cause de lui.
    try {
      final chars = PdfiumStyledText.extractPage(filePath, pageNumber - 1);
      result = _withRealStyles(result, chars);
    } catch (e) {
      debugPrint('Style PDFium ignoré (page $pageNumber) : $e');
    }
    // MuPDF : tailles RÉELLES (matrices de texte déjà corrigées), graisse /
    // italique / famille déduits du vrai nom de police.
    if (mupdfSpans != null) {
      result = _withMupdfStyles(result, mupdfSpans);
    }
    return result;
  }

  /// Applique les styles RÉELS de MuPDF à chaque bloc : taille exacte,
  /// graisse, italique et famille déduits du vrai nom de police (fiable,
  /// là où le rendu bitmap échoue). La couleur reste fournie par PDFium
  /// FFI / le bitmap car MuPDF ne l'expose pas dans ses liaisons Java.
  List<TextBlock> _withMupdfStyles(
    List<TextBlock> blocks,
    List<MupdfSpan> spans,
  ) {
    final out = <TextBlock>[];
    for (final block in blocks) {
      final candidates = spans
          .where((s) {
            final sx = s.centerX, sy = s.centerY;
            return sx >= block.left - 2 &&
                sx <= block.right + 2 &&
                sy >= block.bottom - 2 &&
                sy <= block.top + 2;
          })
          .toList();
      if (candidates.isEmpty) {
        out.add(block);
        continue;
      }
      double sizeSum = 0;
      int sizeLen = 0, boldLen = 0, italicLen = 0, serifLen = 0, monoLen = 0;
      // Union des boîtes de glyphes MuPDF : la vraie hauteur du texte
      // (PDFium rend parfois des boîtes trop courtes → liseré fantôme).
      double inkL = block.left, inkT = block.top, inkR = block.right;
      double inkB = block.bottom;
      for (final s in candidates) {
        final w = s.text.trim().length;
        if (w == 0) continue;
        sizeSum += s.fontSize * w;
        sizeLen += w;
        if (s.isBold) boldLen += w;
        if (s.isItalic) italicLen += w;
        if (s.isMono) {
          monoLen += w;
        } else if (s.isSerif) {
          serifLen += w;
        }
        if (s.left < inkL) inkL = s.left;
        if (s.top > inkT) inkT = s.top;
        if (s.right > inkR) inkR = s.right;
        if (s.bottom < inkB) inkB = s.bottom;
      }
      if (sizeLen == 0) {
        out.add(block);
        continue;
      }
      final TextFamily family;
      if (monoLen * 2 > sizeLen) {
        family = TextFamily.mono;
      } else if (serifLen * 2 > sizeLen) {
        family = TextFamily.serif;
      } else {
        family = TextFamily.sans;
      }
      // Expansion bornée : assez pour les ascendantes/descendantes
      // (liseré fantôme), pas assez pour toucher un élément voisin.
      const vCap = 6.0, hCap = 4.0;
      final grown = block.withBounds(
        left: inkL > block.left - hCap ? inkL : block.left - hCap,
        top: inkT < block.top + vCap ? inkT : block.top + vCap,
        right: inkR < block.right + hCap ? inkR : block.right + hCap,
        bottom: inkB > block.bottom - vCap ? inkB : block.bottom - vCap,
      );
      out.add(
        grown.withRealStyle(
          fontSize: sizeSum / sizeLen,
          bold: boldLen * 2 > sizeLen,
          italic: italicLen * 2 > sizeLen,
          family: family,
        ),
      );
    }
    return out;
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
        // Taille « réelle » valide SEULEMENT si cohérente avec la géométrie
        // du caractère. Certains PDF (titres, couvertures) utilisent une
        // matrice de texte agrandie : la taille de police stockée est alors
        // minuscule (ex. 1 pt pour un titre visuel de 24 pt) et donnerait un
        // calque invisible. Dans ce cas on retombe sur la hauteur de boîte.
        final boxH = c.boxHeight;
        var size = c.fontSize;
        if (boxH > 0 && (size < 0.5 * boxH || size > 1.6 * boxH)) {
          // Matrice agrandie ou taille incohérente → géométrie, légèrement
          // réduite : la boîte « loose » est plus haute que la taille
          // visuelle de la police (ascendantes/descendantes incluses).
          size = boxH * 0.8;
        }
        final key = (size * 2).roundToDouble() / 2;
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

  /// Regroupe les lignes consécutives d'un même paragraphe en un seul bloc.
  ///
  /// Critères géométriques (robustes quel que soit le PDF) :
  /// - espacement vertical normal entre les lignes (pas de saut de
  ///   paragraphe) ;
  /// - hauteurs de ligne comparables ;
  /// - même marge gauche, OU même marge droite avec retrait à gauche
  ///   (dernière ligne d'un paragraphe justifié).
  ///
  /// Critère de style (quand MuPDF est disponible) : deux lignes ne
  /// fusionnent que si elles ont la même graisse et une taille de police
  /// comparable. Un libellé gras (« Problem Statements: »), un titre plus
  /// gros ou une légende ne sont JAMAIS avalés par le corps qui les suit.
  ///
  /// Les listes, titres et colonnes ne sont pas fusionnés : leurs retraits /
  /// espacements / alignements diffèrent.
  List<TextBlock> _mergeLinesIntoParagraphs(
    List<TextBlock> lines,
    List<MupdfSpan>? mupdfSpans,
  ) {
    if (lines.length < 2) return lines;

    final styles = mupdfSpans == null
        ? null
        : [for (final line in lines) _lineStyle(line, mupdfSpans)];

    final result = <TextBlock>[];
    var current = lines.first;
    var currentStyle = styles?[0];
    for (var i = 1; i < lines.length; i++) {
      final next = lines[i];
      final nextStyle = styles?[i];
      if (_sameParagraph(current, next) &&
          _sameStyle(currentStyle, nextStyle)) {
        current = _joinParagraph(current, next);
        currentStyle = nextStyle;
      } else {
        result.add(current);
        current = next;
        currentStyle = nextStyle;
      }
    }
    result.add(current);
    return result;
  }

  /// Style dominant d'une ligne, déduit des spans MuPDF qui la recouvrent.
  /// null si MuPDF n'a rien sur cette ligne → la fusion redevient
  /// purement géométrique pour elle.
  _LineStyle? _lineStyle(TextBlock line, List<MupdfSpan> spans) {
    double sizeSum = 0;
    int len = 0, boldLen = 0;
    for (final s in spans) {
      final sx = s.centerX, sy = s.centerY;
      if (sx < line.left - 2 || sx > line.right + 2) continue;
      if (sy < line.bottom - 2 || sy > line.top + 2) continue;
      final w = s.text.trim().length;
      if (w == 0) continue;
      sizeSum += s.fontSize * w;
      len += w;
      if (s.isBold) boldLen += w;
    }
    if (len == 0) return null;
    return _LineStyle(sizeSum / len, boldLen * 2 > len);
  }

  /// Compatibilité de style requise pour fusionner deux lignes. Sans info
  /// MuPDF (null), on conserve le comportement historique (géométrie seule).
  bool _sameStyle(_LineStyle? upper, _LineStyle? lower) {
    if (upper == null || lower == null) return true;
    if (upper.bold != lower.bold) return false;
    final avg = (upper.size + lower.size) / 2;
    // Tailles à ±10 % près : un titre nettement plus gros reste séparé,
    // les petites variations de crénage/métrique fusionnent toujours.
    if (avg > 0 && (upper.size - lower.size).abs() > 0.10 * avg) {
      return false;
    }
    return true;
  }

  bool _sameParagraph(TextBlock upper, TextBlock lower) {
    final lineH = math.min(upper.height, lower.height);
    if (lineH <= 0) return false;

    // Repère origine bas-gauche : « upper » est AU-DESSUS, donc son bottom
    // est plus grand que le top de « lower ». gap = espace entre les boîtes.
    final gap = upper.bottom - lower.top;
    if (gap < -0.3 * lineH || gap > 0.6 * lineH) return false;

    // Hauteurs de ligne comparables (même corps de texte).
    final ratio = upper.height / lower.height;
    if (ratio < 0.7 || ratio > 1.4) return false;

    // Alignement horizontal.
    final leftDif = (upper.left - lower.left).abs();
    final rightDif = (upper.right - lower.right).abs();
    if (leftDif <= 8) return true; // même marge gauche
    if (rightDif <= 8 && leftDif <= 40) return true; // dernière ligne
    return false;
  }

  TextBlock _joinParagraph(TextBlock a, TextBlock b) {
    final text = '${a.text} ${b.text}'.trim();
    return TextBlock(
      id: TextBlock.computeId(text),
      pageNumber: a.pageNumber,
      text: text,
      left: math.min(a.left, b.left),
      top: math.max(a.top, b.top),
      right: math.max(a.right, b.right),
      bottom: math.min(a.bottom, b.bottom),
      source: BlockSource.native,
      fontSizeHint: math.max(a.fontSizeHint, b.fontSizeHint),
    );
  }
}

/// Style dominant d'une ligne : taille de police réelle (points) + graisse,
/// lus dans les spans MuPDF. Sert de garde anti-fusion entre éléments de
/// styles différents (libellé gras vs corps, titre vs paragraphe…).
class _LineStyle {
  const _LineStyle(this.size, this.bold);

  final double size;
  final bool bold;
}
