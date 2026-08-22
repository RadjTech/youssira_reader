import 'dart:math' as math;

import '../../models/text_block.dart';

/// Calcule la boîte de rendu d'un bloc traduit, partagée entre le calque à
/// l'écran et l'export PDF.
///
/// Principes (leçons tirées des tests sur appareil) :
/// - la traduction dispose de PLUS de place que l'original (le français est
///   plus long), mais jamais au point d'écraser d'autres éléments ;
/// - l'extension de largeur s'arrête au premier obstacle texte sur la même
///   bande verticale, et au plus à 1,75× la largeur d'origine (un en-tête ne
///   doit pas rejoindre un logo posé à droite) ;
/// - un bloc réellement centré ET nettement plus étroit que la page prend
///   toute la largeur utile et centre son texte (titres) ;
/// - un paragraphe pleine largeur reste aligné à gauche (surtout pas
///   centré).
class BlockLayout {
  const BlockLayout({
    required this.left,
    required this.width,
    required this.centered,
  });

  final double left;
  final double width;
  final bool centered;

  /// Marges gauche/droite « utiles » de la page, déduites des blocs réels
  /// (bornées 24–96 pt pour rester saines sur les pages atypiques).
  static ({double left, double right}) pageMargins(
    List<TextBlock> blocks,
    double pageWidth,
  ) {
    if (blocks.isEmpty) return (left: 48.0, right: 48.0);
    final left = math.max(
        24, math.min(96, blocks.map((b) => b.left).reduce(math.min)));
    final right = math.max(
        24,
        math.min(
            96, blocks.map((b) => pageWidth - b.right).reduce(math.min)));
    return (left: left.toDouble(), right: right.toDouble());
  }

  static BlockLayout forBlock(
    TextBlock block, {
    required double pageWidth,
    required double leftMargin,
    required double rightMargin,
    required List<TextBlock> allBlocks,
  }) {
    final contentW = pageWidth - leftMargin - rightMargin;

    // Centré = marges symétriques ET réellement en retrait des deux côtés
    // (un titre), PAS un paragraphe pleine largeur dont les bords touchent
    // les marges (sinon ses lignes seraient centrées : catastrophe).
    final leftGap = block.left;
    final rightGap = pageWidth - block.right;
    final centered = (leftGap - rightGap).abs() < 18 &&
        leftGap > leftMargin + 12 &&
        block.width < contentW * 0.9;

    final boxLeft = centered ? leftMargin : block.left;
    var maxW = pageWidth - rightMargin - boxLeft;

    // Obstacles : tout bloc dont la bande verticale croise la nôtre et qui
    // commence à droite de notre bord droit (en-tête vs logo-texte, deux
    // colonnes…).
    for (final o in allBlocks) {
      if (identical(o, block)) continue;
      final bandOverlap =
          math.min(block.top, o.top) - math.max(block.bottom, o.bottom) > -2;
      if (bandOverlap && o.left > block.right - 1) {
        maxW = math.min(maxW, o.left - boxLeft - 6);
      }
    }

    var width = centered
        ? contentW
        : math.min(maxW, block.width * 1.75);
    width = math.max(width, block.width);

    return BlockLayout(left: boxLeft, width: width, centered: centered);
  }
}
