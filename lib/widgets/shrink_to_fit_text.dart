import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Text that fits a slot of fixed height by shrinking its font, and wraps to
/// two smaller lines only when one line can't hold it.
///
/// One line first, shrinking from the style's size down to [minFontSize].
/// If that still doesn't fit and [twoLineMinFontSize] is set, two lines from
/// [minFontSize] down to [twoLineMinFontSize]. Only past that does the text
/// end in an ellipsis.
///
/// The slot is as tall as the tallest of those layouts from the start, and a
/// single line sits at its bottom, so the widgets around it never move when
/// the text changes. Sizes are before the user's text scaling, so a larger
/// system text size raises the minimums too.
class ShrinkToFitText extends StatelessWidget {
  const ShrinkToFitText(
    this.text, {
    super.key,
    required this.style,
    required this.minFontSize,
    this.twoLineMinFontSize,
    this.textAlign = TextAlign.center,
  });

  final String text;

  /// The style used when the text fits; its `fontSize` is the maximum.
  final TextStyle style;

  /// Smallest font size on one line.
  final double minFontSize;

  /// Smallest font size on two lines, or null to never wrap.
  final double? twoLineMinFontSize;
  final TextAlign textAlign;

  /// Font sizes are tried in these increments.
  static const double _step = 0.5;

  /// Line height of the two-line layout, tighter than the body text's so the
  /// two lines read as one title.
  static const double _twoLineHeight = 1.2;

  @override
  Widget build(BuildContext context) {
    final fullStyle = DefaultTextStyle.of(context).style.merge(style);
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final slotHeight = _slotHeight(fullStyle, direction, scaler);

    return SizedBox(
      height: slotHeight,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final (fontSize, lines) =
              _fit(fullStyle, constraints.maxWidth, direction, scaler);
          return Align(
            alignment: _alignment,
            child: Text(
              text,
              style: style.copyWith(
                fontSize: fontSize,
                height: lines > 1 ? _twoLineHeight : null,
              ),
              maxLines: lines,
              softWrap: lines > 1,
              overflow: TextOverflow.ellipsis,
              textAlign: textAlign,
            ),
          );
        },
      ),
    );
  }

  /// Height of one line at the full size or, when wrapping is allowed, of
  /// two lines at [minFontSize], whichever is taller.
  double _slotHeight(
    TextStyle fullStyle,
    TextDirection direction,
    TextScaler scaler,
  ) {
    // Spaces give an empty slot the same height as a real title.
    final oneLine = _layout(' ', fullStyle, 1, direction, scaler).height;
    if (twoLineMinFontSize == null) return oneLine;
    final twoLines = _layout(
      ' \n ',
      fullStyle.copyWith(fontSize: minFontSize, height: _twoLineHeight),
      2,
      direction,
      scaler,
    ).height;
    return math.max(oneLine, twoLines);
  }

  /// The font size and line count to draw the text with.
  (double, int) _fit(
    TextStyle fullStyle,
    double maxWidth,
    TextDirection direction,
    TextScaler scaler,
  ) {
    final oneLine = _oneLineSize(fullStyle, maxWidth, direction, scaler);
    if (oneLine != null) return (oneLine, 1);
    final floor = twoLineMinFontSize;
    if (floor == null) return (minFontSize, 1);

    bool fitsTwoLines(double size) => !_layout(
          text,
          fullStyle.copyWith(fontSize: size, height: _twoLineHeight),
          2,
          direction,
          scaler,
          maxWidth: maxWidth,
        ).didExceedMaxLines;

    var size = minFontSize;
    while (size > floor && !fitsTwoLines(size)) {
      size -= _step;
    }
    return (math.max(size, floor), 2);
  }

  /// The largest size from the style's down to [minFontSize] at which the
  /// text fits on one line within [maxWidth], or null if none does.
  double? _oneLineSize(
    TextStyle fullStyle,
    double maxWidth,
    TextDirection direction,
    TextScaler scaler,
  ) {
    final maxSize = fullStyle.fontSize ?? 14;
    double widthAt(double size) => _layout(
          text,
          fullStyle.copyWith(fontSize: size),
          1,
          direction,
          scaler,
        ).width;

    final fullWidth = widthAt(maxSize);
    if (text.isEmpty || fullWidth <= maxWidth) return maxSize;
    if (widthAt(minFontSize) > maxWidth) return null;
    // Width grows about linearly with the size, so start from the
    // proportional guess, then correct it a step at a time either way
    // (rounding and nonlinear text scaling can put it off by one).
    var size = (maxSize * maxWidth / fullWidth / _step).floor() * _step;
    size = size.clamp(minFontSize, maxSize - _step).toDouble();
    while (size > minFontSize && widthAt(size) > maxWidth) {
      size -= _step;
    }
    while (size + _step < maxSize && widthAt(size + _step) <= maxWidth) {
      size += _step;
    }
    return size;
  }

  /// Bottom of the slot, so a single line sits right above what follows.
  AlignmentGeometry get _alignment => switch (textAlign) {
        TextAlign.left => Alignment.bottomLeft,
        TextAlign.right => Alignment.bottomRight,
        TextAlign.start ||
        TextAlign.justify =>
          AlignmentDirectional.bottomStart,
        TextAlign.end => AlignmentDirectional.bottomEnd,
        TextAlign.center => Alignment.bottomCenter,
      };

  static ({double width, double height, bool didExceedMaxLines}) _layout(
    String text,
    TextStyle style,
    int maxLines,
    TextDirection direction,
    TextScaler scaler, {
    double maxWidth = double.infinity,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: direction,
      textScaler: scaler,
      maxLines: maxLines,
    )..layout(maxWidth: maxWidth);
    final metrics = (
      width: painter.width,
      height: painter.height,
      didExceedMaxLines: painter.didExceedMaxLines,
    );
    painter.dispose();
    return metrics;
  }
}
