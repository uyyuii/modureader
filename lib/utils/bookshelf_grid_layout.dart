import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Geometry for the bookshelf cover grid.
///
/// Both the shelf page and the opened-folder dialog call
/// [resolveBookshelfGridGeometry] so the "columns / rows" settings always
/// produce the same card size in either place. Keep the row formula in one
/// place: a copy here would drift as soon as one screen is tweaked.
class BookshelfGridGeometry {
  const BookshelfGridGeometry({
    required this.columns,
    required this.childWidth,
    required this.childHeight,
    required this.childAspectRatio,
  });

  final int columns;
  final double childWidth;
  final double childHeight;
  final double childAspectRatio;
}

BookshelfGridGeometry resolveBookshelfGridGeometry({
  required double maxWidth,
  required double viewportHeight,
  required EdgeInsets padding,
  required double crossSpacing,
  required double mainSpacing,
  required int preferredColumns,
  required int rows,
  required double coverWidth,
  double naturalAspectDivisor = 2.1,
}) {
  // 0 keeps the legacy behaviour: derive the column count from coverWidth.
  final columns = preferredColumns > 0
      ? preferredColumns
      : math.max(1, maxWidth ~/ coverWidth);
  final childWidth = math.max(
      1.0,
      (maxWidth - padding.horizontal - (columns - 1) * crossSpacing) /
          columns);
  // rows > 0 fixes the number of visible rows per screen by deriving the
  // card height from the viewport; rows == 0 keeps natural scrolling height.
  final childHeight = rows > 0
      ? math.max(
          80.0,
          (viewportHeight - padding.vertical - (rows - 1) * mainSpacing) /
              rows)
      : childWidth * naturalAspectDivisor;
  return BookshelfGridGeometry(
    columns: columns,
    childWidth: childWidth,
    childHeight: childHeight,
    childAspectRatio: childWidth / childHeight,
  );
}
