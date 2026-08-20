import 'package:flutter_test/flutter_test.dart';
import 'package:youssira_reader/core/models/text_block.dart';
import 'package:youssira_reader/core/utils/coords.dart';

void main() {
  group('TextBlock.computeId', () {
    test('normalise les espaces avant hachage', () {
      expect(
        TextBlock.computeId('Bonjour   le monde'),
        TextBlock.computeId('Bonjour le monde'),
      );
    });

    test('diffère pour des textes différents', () {
      expect(TextBlock.computeId('a'), isNot(TextBlock.computeId('b')));
    });
  });

  group('pdfRectToWidget', () {
    test('convertit le repère PDF (bas-gauche) vers le repère widget', () {
      // Page A4 (595.32 x 841.92 pt) affichée à l'échelle 0.5.
      final rect = pdfRectToWidget(
        left: 0,
        top: 841.92, // haut de la page en coordonnées PDF
        right: 595.32,
        bottom: 741.92, // bande de 100 pt sous le haut de page
        pageWidthPt: 595.32,
        pageHeightPt: 841.92,
        widgetWidth: 297.66,
        widgetHeight: 420.96,
      );

      expect(rect.left, closeTo(0, 0.01));
      expect(rect.top, closeTo(0, 0.01)); // haut de page → y = 0
      expect(rect.right, closeTo(297.66, 0.01));
      expect(rect.bottom, closeTo(50, 0.01)); // 100 pt × 0.5
    });
  });
}
