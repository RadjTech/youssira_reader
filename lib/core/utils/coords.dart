import 'dart:ui' show Rect;

/// Convertit un rectangle exprimé en **coordonnées PDF** vers le repère d'un
/// widget Flutter.
///
/// Repère PDF : origine en BAS à gauche, axe Y vers le haut, unité = point
/// (1/72 pouce), avec `top > bottom`.
/// Repère widget : origine en HAUT à gauche, axe Y vers le bas, en pixels.
///
/// [pageWidthPt] / [pageHeightPt] : dimensions de la page PDF en points.
/// [widgetWidth] / [widgetHeight] : dimensions rendues du widget de page.
Rect pdfRectToWidget({
  required double left,
  required double top,
  required double right,
  required double bottom,
  required double pageWidthPt,
  required double pageHeightPt,
  required double widgetWidth,
  required double widgetHeight,
}) {
  final sx = widgetWidth / pageWidthPt;
  final sy = widgetHeight / pageHeightPt;
  return Rect.fromLTRB(
    left * sx,
    (pageHeightPt - top) * sy,
    right * sx,
    (pageHeightPt - bottom) * sy,
  );
}
