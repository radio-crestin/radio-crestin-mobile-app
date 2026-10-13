import 'package:flutter/material.dart';

/// Single-line text that shrinks its font, down to [minFontSize], to fit the
/// available width, and ends in an ellipsis only below that.
///
/// Always as tall as one line at the full font size, so the widgets around it
/// never move when the text changes, however long it is. Sizes are before the
/// user's text scaling, so a larger system text size raises the minimum too.
class ShrinkToFitText extends StatelessWidget {
  const ShrinkToFitText(
    this.text, {
    super.key,
    required this.style,
    required this.minFontSize,
    this.textAlign = TextAlign.center,
  });

  final String text;

  /// The style used when the text fits; its `fontSize` is the maximum.
  final TextStyle style;
  final double minFontSize;
  final TextAlign textAlign;

  /// Font sizes are tried in these increments.
  static const double _step = 0.5;

  @override
  Widget build(BuildContext context) {
    final fullStyle = DefaultTextStyle.of(context).style.merge(style);
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    // A space gives an empty line the same height as a real one.
    final lineHeight = _measure(' ', fullStyle, direction, scaler).height;

    return SizedBox(
      height: lineHeight,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final fontSize = _fittingFontSize(
            fullStyle,
            constraints.maxWidth,
            direction,
            scaler,
          );
          return Align(
            alignment: _alignment(direction),
            child: Text(
              text,
              style: style.copyWith(fontSize: fontSize),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              textAlign: textAlign,
            ),
          );
        },
      ),
    );
  }

  /// The largest size from the style's down to [minFontSize] at which the
  /// text fits on one line within [maxWidth].
  double _fittingFontSize(
    TextStyle fullStyle,
    double maxWidth,
    TextDirection direction,
    TextScaler scaler,
  ) {
    final maxSize = fullStyle.fontSize ?? 14;
    double widthAt(double size) => _measure(
          text,
          fullStyle.copyWith(fontSize: size),
          direction,
          scaler,
        ).width;

    final fullWidth = widthAt(maxSize);
    if (text.isEmpty || fullWidth <= maxWidth) return maxSize;
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
    return size < minFontSize ? minFontSize : size;
  }

  AlignmentGeometry _alignment(TextDirection direction) => switch (textAlign) {
        TextAlign.left => Alignment.centerLeft,
        TextAlign.right => Alignment.centerRight,
        TextAlign.start ||
        TextAlign.justify =>
          AlignmentDirectional.centerStart,
        TextAlign.end => AlignmentDirectional.centerEnd,
        TextAlign.center => Alignment.center,
      };

  static Size _measure(
    String text,
    TextStyle style,
    TextDirection direction,
    TextScaler scaler,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: direction,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final size = painter.size;
    painter.dispose();
    return size;
  }
}
