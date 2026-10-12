import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

const double _toolbarHeight = 48;
const double _leadingWidth = 56;
const double _maxTextScale = 1.4;
const double _backdropOpacity = 0.8;
const double _blurSigma = 20;
const Duration _fadeDuration = Duration(milliseconds: 150);

/// Pinned header with a back button and a centred title, like an iOS
/// navigation bar.
///
/// The bar keeps the page colour until content scrolls beneath it. Only then
/// does it turn translucent, with a blur and a hairline, so it never picks up
/// the Material 3 scrolled-under tint.
class PinnedTitleSliverHeader extends StatelessWidget {
  const PinnedTitleSliverHeader({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return SliverPersistentHeader(
      pinned: true,
      delegate: _PinnedTitleHeaderDelegate(
        title: title,
        topPadding: MediaQuery.paddingOf(context).top,
        backgroundColor: theme.scaffoldBackgroundColor,
        foregroundColor: isDark ? Colors.white : Colors.black,
        hairlineColor: theme.dividerColor,
        hairlineWidth: 1 / MediaQuery.devicePixelRatioOf(context),
        overlayStyle: theme.appBarTheme.systemOverlayStyle ??
            (isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark),
      ),
    );
  }
}

class _PinnedTitleHeaderDelegate extends SliverPersistentHeaderDelegate {
  _PinnedTitleHeaderDelegate({
    required this.title,
    required this.topPadding,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.hairlineColor,
    required this.hairlineWidth,
    required this.overlayStyle,
  });

  final String title;
  final double topPadding;
  final Color backgroundColor;
  final Color foregroundColor;
  final Color hairlineColor;
  final double hairlineWidth;
  final SystemUiOverlayStyle overlayStyle;

  @override
  double get minExtent => topPadding + _toolbarHeight;

  @override
  double get maxExtent => minExtent;

  /// Pulling down on iOS grows the bar instead of dragging it away from the
  /// status bar, so the back button and title stay put while the list
  /// bounces.
  @override
  OverScrollHeaderStretchConfiguration get stretchConfiguration =>
      OverScrollHeaderStretchConfiguration();

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    // Without an `AppBar` nothing else sets the status bar icon colours.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: _maxTextScale,
        child: _BarBackground(
          // `overlapsContent` is always false for the first sliver, so the
          // scroll offset is what tells us the list is passing under the bar.
          scrolledUnder: shrinkOffset > 0,
          color: backgroundColor,
          hairlineColor: hairlineColor,
          hairlineWidth: hairlineWidth,
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: EdgeInsets.only(top: topPadding),
              child: SizedBox(
                height: _toolbarHeight,
                child: _Toolbar(title: title, color: foregroundColor),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_PinnedTitleHeaderDelegate oldDelegate) =>
      title != oldDelegate.title ||
      topPadding != oldDelegate.topPadding ||
      backgroundColor != oldDelegate.backgroundColor ||
      foregroundColor != oldDelegate.foregroundColor ||
      hairlineColor != oldDelegate.hairlineColor ||
      hairlineWidth != oldDelegate.hairlineWidth ||
      overlayStyle != oldDelegate.overlayStyle;
}

/// Opaque in the page colour at rest; translucent and blurred, with a
/// hairline, once content scrolls beneath it.
class _BarBackground extends StatelessWidget {
  const _BarBackground({
    required this.scrolledUnder,
    required this.color,
    required this.hairlineColor,
    required this.hairlineWidth,
    required this.child,
  });

  final bool scrolledUnder;
  final Color color;
  final Color hairlineColor;
  final double hairlineWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        // Blurring is only paid for while something is actually behind.
        enabled: scrolledUnder,
        filter: ImageFilter.blur(sigmaX: _blurSigma, sigmaY: _blurSigma),
        child: AnimatedContainer(
          duration: _fadeDuration,
          curve: Curves.easeInOut,
          decoration: BoxDecoration(
            color: scrolledUnder
                ? color.withValues(alpha: _backdropOpacity)
                : color,
            border: Border(
              bottom: BorderSide(
                color: scrolledUnder
                    ? hairlineColor
                    : hairlineColor.withValues(alpha: 0),
                width: hairlineWidth,
              ),
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.title, required this.color});

  final String title;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return NavigationToolbar(
      // The toolbar forces its full height on the leading slot, which would
      // stretch the button's round highlight into an oval. Centring it in a
      // fixed slot, as `AppBar` does, keeps it a circle.
      leading: SizedBox(
        width: _leadingWidth,
        child: Center(
          child: IconButton(
            tooltip: 'Înapoi',
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 22),
            color: color,
            onPressed: () => Navigator.maybePop(context),
          ),
        ),
      ),
      middle: Semantics(
        header: true,
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          // The inherited body style adds Material's wide 0.25 tracking;
          // iOS sets navigation titles at -0.41.
          style: (Theme.of(context).textTheme.titleMedium ??
                  const TextStyle())
              .copyWith(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.41,
            color: color,
          ),
        ),
      ),
    );
  }
}
