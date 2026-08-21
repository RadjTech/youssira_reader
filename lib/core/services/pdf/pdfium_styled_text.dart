import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:pdfium_flutter/pdfium_flutter.dart';

/// Un caractère extrait directement via l'API C de PDFium (`FPDFText`), avec
/// son style réel : taille de police, graisse et couleur de remplissage.
///
/// Coordonnées en points PDF, repère origine bas-gauche — la même convention
/// que `TextBlock` et que `PdfPageTextFragment` de pdfrx.
class PdfStyledChar {
  const PdfStyledChar({
    required this.codeUnit,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.fontSize,
    required this.fontWeight,
    required this.colorRgb,
  });

  /// Code point Unicode du caractère.
  final int codeUnit;

  /// Boîte « loose » du caractère (points PDF, origine bas-gauche).
  final double left;
  final double top;
  final double right;
  final double bottom;

  /// Taille de police en points PDF (0 = inconnue).
  final double fontSize;

  /// Graisse PDFium : 100..900 (400 = normal, 700 = gras) ; -1 = inconnue.
  final int fontWeight;

  /// Couleur de remplissage 0xRRGGBB, ou null si le PDF ne la précise pas.
  final int? colorRgb;

  double get centerX => (left + right) / 2;
  double get centerY => (top + bottom) / 2;

  bool get isWhitespace => codeUnit <= 0x20;
}

/// Extraction de texte **stylé** via l'API C de PDFium (FFI directe).
///
/// Pourquoi ce service existe : pdfrx expose le texte et ses boîtes, mais ni
/// la taille de police, ni la graisse, ni la couleur — que PDFium connaît
/// pourtant (`FPDFText_GetFontSize` / `GetFontWeight` / `GetFillColor`).
/// On appelle donc le même `libpdfium.so` déjà chargé par pdfrx :
/// - **zéro poids APK supplémentaire** (aucune nouvelle bibliothèque) ;
/// - **zéro risque de licence** (PDFium est sous licence BSD) ;
/// - **100 % hors-ligne**, aucune dépendance serveur.
///
/// Toute erreur (symbole absent, fichier illisible…) est avalée et renvoie
/// une liste vide : le pipeline retombe alors sur ses heuristiques bitmap
/// d'origine. Jamais bloquant.
class PdfiumStyledText {
  /// Caractères stylés de la page [pageIndex] (0-based) du fichier
  /// [filePath]. Liste vide en cas d'échec ou de page sans texte natif.
  static List<PdfStyledChar> extractPage(String filePath, int pageIndex) {
    FPDF_DOCUMENT? doc;
    ffi.Pointer<ffi.Char>? pathPtr;
    try {
      final pdfium = pdfiumBindings;
      pathPtr = filePath.toNativeUtf8().cast<ffi.Char>();
      doc = pdfium.FPDF_LoadDocument(pathPtr, ffi.nullptr);
      if (doc == ffi.nullptr) return const [];
      return _extractFromDocument(pdfium, doc, pageIndex);
    } catch (_) {
      return const [];
    } finally {
      if (pathPtr != null) malloc.free(pathPtr);
      if (doc != null && doc != ffi.nullptr) {
        try {
          pdfiumBindings.FPDF_CloseDocument(doc);
        } catch (_) {}
      }
    }
  }

  static List<PdfStyledChar> _extractFromDocument(
    PDFium pdfium,
    FPDF_DOCUMENT doc,
    int pageIndex,
  ) {
    final page = pdfium.FPDF_LoadPage(doc, pageIndex);
    if (page == ffi.nullptr) return const [];
    final textPage = pdfium.FPDFText_LoadPage(page);
    if (textPage == ffi.nullptr) {
      pdfium.FPDF_ClosePage(page);
      return const [];
    }
    final rect = calloc<FS_RECTF>();
    final r = calloc<ffi.Uint32>();
    final g = calloc<ffi.Uint32>();
    final b = calloc<ffi.Uint32>();
    final a = calloc<ffi.Uint32>();
    try {
      final count = pdfium.FPDFText_CountChars(textPage);
      if (count <= 0) return const [];

      final chars = <PdfStyledChar>[];
      for (var i = 0; i < count; i++) {
        final unicode = pdfium.FPDFText_GetUnicode(textPage, i);
        if (pdfium.FPDFText_GetLooseCharBox(textPage, i, rect) == 0) {
          continue;
        }
        int? color;
        if (pdfium.FPDFText_GetFillColor(textPage, i, r, g, b, a) != 0) {
          color = (r.value << 16) | (g.value << 8) | b.value;
        }
        chars.add(PdfStyledChar(
          codeUnit: unicode,
          left: rect.ref.left,
          top: rect.ref.top,
          right: rect.ref.right,
          bottom: rect.ref.bottom,
          fontSize: pdfium.FPDFText_GetFontSize(textPage, i),
          fontWeight: pdfium.FPDFText_GetFontWeight(textPage, i),
          colorRgb: color,
        ));
      }
      return chars;
    } finally {
      calloc.free(rect);
      calloc.free(r);
      calloc.free(g);
      calloc.free(b);
      calloc.free(a);
      pdfium.FPDFText_ClosePage(textPage);
      pdfium.FPDF_ClosePage(page);
    }
  }
}
