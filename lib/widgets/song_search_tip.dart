import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme.dart';
import '../utils.dart';

/// Decides when the song search tip is due, and remembers that the user
/// has seen it so it shows only once.
class SongSearchTipMemory {
  SongSearchTipMemory._();

  static const _seenKey = 'song_search_tip_seen';

  /// User actions after which the tip may show ([Utils.actionsMade]): past
  /// the first minutes, while a new user is still learning to start a
  /// station. Users updating from a version without the tip are long past
  /// it, so they see it the first time the player opens on a song.
  static const int minActions = 5;

  /// Whether the tip should show at the next chance: it was never
  /// dismissed and the user has made [minActions]. Unreadable preferences
  /// count as not due, so a storage error never shows it.
  static Future<bool> isDue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_seenKey) ?? false) return false;
      return Utils.actionsMade(prefs) >= minActions;
    } catch (_) {
      return false;
    }
  }

  /// Records that the tip was dismissed.
  static Future<void> markSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_seenKey, true);
    } catch (_) {
      // Worst case the tip shows once more.
    }
  }
}

/// A bubble above [child] telling that a tap on the song searches YouTube.
///
/// It rises while [visible] and sinks once it turns false. "Am înțeles", or
/// a tap anywhere outside the bubble, calls [onDismiss]; that tap still
/// reaches what it lands on, so the bubble never stands in the way.
class SongSearchTip extends StatefulWidget {
  const SongSearchTip({
    super.key,
    required this.visible,
    required this.onDismiss,
    required this.child,
  });

  final bool visible;
  final VoidCallback onDismiss;

  /// The song title and artist the bubble points at.
  final Widget child;

  static const String title = 'Caută melodia pe YouTube';
  static const String message =
      'Atinge titlul sau artistul ca s-o asculți acolo.';
  static const String dismissLabel = 'Am înțeles';

  @override
  State<SongSearchTip> createState() => _SongSearchTipState();
}

class _SongSearchTipState extends State<SongSearchTip>
    with SingleTickerProviderStateMixin {
  /// The bubble's left edge, left of the song's, and the gap between its
  /// arrow tip and the top of the song.
  static const _offset = Offset(-6, -8);

  final _link = LayerLink();
  final _portal = OverlayPortalController();
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
    reverseDuration: const Duration(milliseconds: 200),
  )..addStatusListener(_onStatus);
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.fastOutSlowIn,
    reverseCurve: Curves.easeIn,
  );
  late final Animation<double> _scale =
      Tween(begin: 0.9, end: 1.0).animate(_curve);

  @override
  void initState() {
    super.initState();
    // The portal stays open and the bubble in it is built only while
    // visible or fading out: opening the portal when [visible] turns true
    // would call `show()` during a build, which it forbids.
    _portal.show();
    if (widget.visible) _controller.forward();
  }

  @override
  void didUpdateWidget(SongSearchTip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) return;
    widget.visible ? _controller.forward() : _controller.reverse();
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Drops the bubble once it has faded out.
  void _onStatus(AnimationStatus status) {
    if (status.isDismissed && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: _buildBubble,
        child: widget.child,
      ),
    );
  }

  Widget _buildBubble(BuildContext context) {
    if (!widget.visible && _controller.isDismissed) {
      return const SizedBox.shrink();
    }
    return Align(
      alignment: AlignmentDirectional.topStart,
      child: CompositedTransformFollower(
        link: _link,
        showWhenUnlinked: false,
        targetAnchor: Alignment.topLeft,
        followerAnchor: Alignment.bottomLeft,
        offset: _offset,
        child: FadeTransition(
          opacity: _curve,
          child: ScaleTransition(
            scale: _scale,
            alignment: Alignment.bottomLeft,
            child: TapRegion(
              onTapOutside: (_) => widget.onDismiss(),
              child: _TipBubble(onDismiss: widget.onDismiss),
            ),
          ),
        ),
      ),
    );
  }
}

/// The bubble: a card in the theme's inverse surface, the same one as the
/// status snackbar, with an arrow pointing down at the song.
class _TipBubble extends StatelessWidget {
  const _TipBubble({required this.onDismiss});

  /// Width at the standard text size; it grows with the text, up to the
  /// screen's width less a margin.
  static const double _width = 264;
  static const double _screenMargin = 32;

  /// The arrow's size, and how far its left edge sits from the card's.
  static const Size _arrowSize = Size(16, 8);
  static const double _arrowInset = 20;

  static const _radius = BorderRadius.all(Radius.circular(14));

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).statusSnackbarColors;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final width = math.min(
      MediaQuery.textScalerOf(context).scale(_width),
      math.max(_width, screenWidth - _screenMargin),
    );
    return Semantics(
      container: true,
      liveRegion: true,
      onDismiss: onDismiss,
      child: SizedBox(
        width: width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: colors.background,
                borderRadius: _radius,
                boxShadow: const [
                  BoxShadow(
                    color: AppColors.statusSnackbarShadow,
                    blurRadius: 20,
                    offset: Offset(0, 6),
                  ),
                ],
              ),
              child: Material(
                type: MaterialType.transparency,
                child: _TipContent(onDismiss: onDismiss),
              ),
            ),
            // Left-anchored like the bubble itself, which hangs from the
            // song's top-left corner.
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: _arrowInset),
                child: CustomPaint(
                  size: _arrowSize,
                  painter: _ArrowPainter(colors.background),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TipContent extends StatelessWidget {
  const _TipContent({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).statusSnackbarColors;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 14, 6, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 10),
            child: Text(
              SongSearchTip.title,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                height: 20 / 15,
                color: colors.text,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 10),
            child: Text(
              SongSearchTip.message,
              style: TextStyle(
                fontSize: 14,
                height: 19 / 14,
                color: colors.textSecondary,
              ),
            ),
          ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(
              onPressed: onDismiss,
              style: TextButton.styleFrom(
                foregroundColor: colors.action,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(48, 44),
                textStyle: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              child: const Text(SongSearchTip.dismissLabel),
            ),
          ),
        ],
      ),
    );
  }
}

/// A triangle pointing down, in the bubble's color.
class _ArrowPainter extends CustomPainter {
  const _ArrowPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_ArrowPainter oldDelegate) => oldDelegate.color != color;
}
