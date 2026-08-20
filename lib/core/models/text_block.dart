import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Origine d'un bloc de texte extrait d'une page.
enum BlockSource {
  /// Texte natif du PDF, extrait via PDFium.
  native,

  /// Texte reconnu par OCR (page scannée / photo de document).
  ocr,
}

/// Un bloc de texte d'une page PDF, avec ses coordonnées exactes.
///
/// Les coordonnées sont exprimées en **points PDF** (1 pt = 1/72 pouce) dans
/// le repère PDF : origine en BAS à gauche, axe Y vers le haut. Pour un bloc,
/// on a donc toujours [top] > [bottom].
///
/// La conversion vers le repère Flutter (origine en haut à gauche) se fait
/// dans `core/utils/coords.dart`.
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

  double get width => right - left;
  double get height => top - bottom;

  /// Calcule un identifiant stable pour un texte donné.
  static String computeId(String text) {
    final normalized = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    return sha256.convert(utf8.encode(normalized)).toString().substring(0, 16);
  }

  @override
  String toString() => 'TextBlock(p$pageNumber, "$text")';
}
