import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Origine d'un bloc de texte extrait d'une page.
enum BlockSource {
  /// Texte natif du PDF, extrait via PDFium.
  native,

  /// Texte reconnu par OCR (page scannée / photo de document).
  ocr,
}

/// Un bloc de texte d'une page PDF, avec ses coordonnées exactes et son style
/// visuel échantillonné depuis le rendu bitmap de la page.
///
/// Les coordonnées sont exprimées en **points PDF** (1 pt = 1/72 pouce) dans
/// le repère PDF : origine en BAS à gauche, axe Y vers le haut. Pour un bloc,
/// on a donc toujours [top] > [bottom].
class TextBlock {
  const TextBlock({
    required this.id,
    required this.pageNumber,
    required this.text,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.source,
    required this.fontSizeHint,
    this.textColor = 0xDE1A1A1A,
    this.backgroundColor = 0xFFFFFFFF,
    this.bold = false,
    this.uniformBackground = true,
  });

  /// Identifiant stable du contenu du bloc (hash). Sert de clé au cache de
  /// traductions : un même texte traduit une seule fois, tous documents
  /// confondus.
  final String id;

  /// Numéro de page, 1-based (convention PDF).
  final int pageNumber;

  /// Texte du bloc.
  final String text;

  /// Rectangle englobant, en points PDF (repère origine bas-gauche).
  final double left;
  final double top;
  final double right;
  final double bottom;

  final BlockSource source;

  /// Hauteur de ligne estimée (points PDF) — utilisée pour dimensionner la
  /// police du calque de traduction.
  final double fontSizeHint;

  /// Couleur du texte original (ARGB), échantillonnée sur le rendu bitmap.
  final int textColor;

  /// Couleur de fond du bloc (ARGB), échantillonnée sur le rendu bitmap.
  /// Permet au calque de se fondre dans la page (fond gris d'un encadré,
  /// fond coloré d'un bandeau…).
  final int backgroundColor;

  /// Graisse détectée (heuristique : densité d'encre relative à la page).
  final bool bold;

  /// true si le fond du bloc est uniforme (page blanche, encadré uni…).
  /// false = fond complexe (image, capture, dégradé) : le calque ne pose
  /// alors AUCUN rectangle (style Google Lens : texte avec halo).
  final bool uniformBackground;

  double get width => right - left;
  double get height => top - bottom;

  /// Calcule un identifiant stable pour un texte donné.
  static String computeId(String text) {
    final normalized = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    return sha256.convert(utf8.encode(normalized)).toString().substring(0, 16);
  }

  TextBlock copyWithStyle({
    required int textColor,
    required int backgroundColor,
    required bool bold,
    required bool uniformBackground,
  }) {
    return TextBlock(
      id: id,
      pageNumber: pageNumber,
      text: text,
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      source: source,
      fontSizeHint: fontSizeHint,
      textColor: textColor,
      backgroundColor: backgroundColor,
      bold: bold,
      uniformBackground: uniformBackground,
    );
  }

  @override
  String toString() => 'TextBlock(p$pageNumber, "$text")';
}
