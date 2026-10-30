import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../widgets/snapshot_fade_transition.dart';
import '../tv_theme.dart';
import 'desktop_mini_player.dart';
import 'now_playing_controls.dart';

/// "Se redă acum" as the player bar opened up: the panel grows out of the
/// bar at the bottom of the window, up to the title bar, and shrinks back
/// into it when it closes.
///
/// It keeps the bar's sides, bottom and corners all along, so it reads as
/// the bar itself growing, not a dialog that appears: it starts as the
/// bar, in its color, and fills in the panel's content as it grows, while
/// the window around it dims. Closing, the content leaves first and the
/// panel lands back on the bar, which shows again under it.
///
/// A click on the dimmed window, like Esc, closes it.
class DesktopNowPlayingRoute extends PopupRoute<void> {
  DesktopNowPlayingRoute({required this.builder, super.settings});

  /// Builds the panel's content, laid out at the panel's full size.
  final WidgetBuilder builder;

  /// Where the panel is in a window of [size] whose title bar takes [top]:
  /// the bar's sides and bottom, up to under the title bar.
  static Rect panelRectIn(Size size, {required double top}) {
    final bar = DesktopMiniPlayer.rectIn(size);
    return Rect.fromLTRB(
      bar.left,
      math.min(math.max(top, DesktopMiniPlayer.margin.bottom), bar.top),
      bar.right,
      bar.bottom,
    );
  }

  @override
  Color get barrierColor => const Color(0x99000000);

  @override
  bool get barrierDismissible => true;

  @override
  String get barrierLabel => 'Închide';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 380);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 300);

  /// The panel's content fades as an image of it while the panel grows or
  /// shrinks; a [PopupRoute] says no by default, being meant for small
  /// popups, but this one grows over most of the window.
  @override
  bool get allowSnapshotting => true;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) =>
      _GrowingPanel(
        animation: animation,
        allowSnapshotting: allowSnapshotting,
        child: Builder(builder: builder),
      );
}

/// The panel at the size and stage [animation] gives it, between the bar
/// (0) and the open panel (1).
class _GrowingPanel extends StatefulWidget {
  const _GrowingPanel({
    required this.animation,
    required this.allowSnapshotting,
    required this.child,
  });

  final Animation<double> animation;

  /// Whether the content may fade as an image of it, as the route's
  /// [ModalRoute.allowSnapshotting] tells.
  final bool allowSnapshotting;

  final Widget child;

  @override
  State<_GrowingPanel> createState() => _GrowingPanelState();
}

class _GrowingPanelState extends State<_GrowingPanel> {
  /// How far the panel has grown: fast out of the bar, settling softly
  /// at the top; closing, it leaves the top fast and lands softly on the
  /// bar.
  late final CurvedAnimation _growth = CurvedAnimation(
    parent: widget.animation,
    curve: Curves.fastOutSlowIn,
    reverseCurve: Curves.fastOutSlowIn.flipped,
  );

  /// The content shows once the panel has grown this far, so it never
  /// crowds into a panel barely taller than the bar.
  static const Interval _content = Interval(0.4, 1, curve: Curves.easeOut);

  late final Animation<double> _contentOpacity =
      _growth.drive(CurveTween(curve: _content));

  @override
  void dispose() {
    _growth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final bar = DesktopMiniPlayer.rectIn(size);
        final panel = DesktopNowPlayingRoute.panelRectIn(size, top: top);
        // Laid out once, at the open panel's size; the growing panel shows
        // its top part. While the panel grows or shrinks, the content fades
        // as an image of it, taken once at that size, which the panel only
        // moves and clips: fading it live would draw the whole panel
        // through an offscreen layer every frame.
        final content = OverflowBox(
          alignment: Alignment.topCenter,
          minWidth: panel.width,
          maxWidth: panel.width,
          minHeight: panel.height,
          maxHeight: panel.height,
          child: SnapshotFadeTransition(
            opacity: _contentOpacity,
            allowSnapshotting: widget.allowSnapshotting,
            // For the content's text style and ink, as a dialog's has; in
            // the image, so an ink splash fades with the rest.
            child: Material(
              type: MaterialType.transparency,
              child: widget.child,
            ),
          ),
        );
        return AnimatedBuilder(
          animation: _growth,
          child: content,
          builder: (context, content) {
            final grown = _growth.value;
            return Stack(
              children: [
                Positioned.fromRect(
                  rect: Rect.lerp(bar, panel, grown)!,
                  child: _Surface(grown: grown, child: content!),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// The panel's rounded surface, from the bar's color to the panel's as it
/// grows, with its content.
class _Surface extends StatelessWidget {
  const _Surface({required this.grown, required this.child});

  /// 0 at the bar, 1 open.
  final double grown;
  final Widget child;

  /// While the panel is this close to the bar its surface fades over it,
  /// so the bar shows through at first and again as it lands.
  static const Interval _surface = Interval(0, 0.12);

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(DesktopMiniPlayer.radius);
    return Opacity(
      opacity: _surface.transform(grown),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Color.lerp(
            DesktopTokens.raisedSurface,
            NowPlayingPalette.panel,
            grown,
          ),
          borderRadius: radius,
          border: Border.all(color: NowPlayingPalette.edge),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 18,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: ClipRRect(borderRadius: radius, child: child),
      ),
    );
  }
}
