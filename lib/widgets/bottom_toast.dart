import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shows a Revolut-style bottom card toast that slides up from the bottom.
/// Features a drag handle, large centered icon, centered text,
/// and an animated progress line showing remaining display time.
///
/// Set [isError] to true for a bold red error variant.
///
/// Returns the [OverlayEntry] so callers can remove it if needed
/// (e.g. to replace with a new toast).
OverlayEntry showBottomToast(
  BuildContext context, {
  required String title,
  required String message,
  IconData icon = Icons.check_circle_rounded,
  Color? iconColor,
  bool isError = false,
  Duration duration = const Duration(seconds: 4),
  VoidCallback? onDismissed,
}) {
  final bottomPadding = MediaQuery.of(context).padding.bottom;
  bool removed = false;

  late OverlayEntry entry;
  final resolvedIconColor = iconColor ?? const Color(0xFF34C759);
  final resolvedDuration = isError ? const Duration(seconds: 5) : duration;
  entry = OverlayEntry(
    builder: (context) => _BottomToastWidget(
      title: title,
      message: message,
      icon: icon,
      iconColor: resolvedIconColor,
      isError: isError,
      bottomPadding: bottomPadding,
      duration: resolvedDuration,
      onDismissed: () {
        if (!removed) {
          removed = true;
          entry.remove();
          onDismissed?.call();
        }
      },
    ),
  );

  Overlay.of(context).insert(entry);
  return entry;
}

/// Safely removes an [OverlayEntry] returned by [showBottomToast].
/// No-op if already removed.
void removeBottomToast(OverlayEntry? entry) {
  if (entry == null) return;
  try {
    entry.remove();
  } catch (_) {
    // Already removed (auto-dismissed or swiped away)
  }
}

class _BottomToastWidget extends StatefulWidget {
  final String title;
  final String message;
  final IconData icon;
  final Color iconColor;
  final bool isError;
  final double bottomPadding;
  final Duration duration;
  final VoidCallback onDismissed;

  const _BottomToastWidget({
    required this.title,
    required this.message,
    required this.icon,
    required this.iconColor,
    required this.isError,
    required this.bottomPadding,
    required this.duration,
    required this.onDismissed,
  });

  @override
  State<_BottomToastWidget> createState() => _BottomToastWidgetState();
}

class _BottomToastWidgetState extends State<_BottomToastWidget>
    with TickerProviderStateMixin {
  late final AnimationController _slideController;
  late final AnimationController _timerController;
  late final AnimationController _springController;
  late final Animation<Offset> _slideAnimation;
  late final Animation<double> _fadeAnimation;
  late Animation<double> _springAnimation;

  // ValueNotifier avoids setState — only the Transform.translate rebuilds.
  final ValueNotifier<double> _dragOffset = ValueNotifier(0.0);
  bool _dismissing = false;

  static const double _dismissThreshold = 60.0;
  static const double _velocityThreshold = 300.0;

  // Pre-computed colors (static for the widget's lifetime).
  late final Color _bgColor;
  late final Color _borderColor;
  late final Color _progressColor;
  late final Color _iconCircleColor;
  late final Color _iconDisplayColor;
  late final Color _messageColor;
  late final BoxDecoration _cardDecoration;

  @override
  void initState() {
    super.initState();

    // Compute colors once — they never change.
    _bgColor = widget.isError
        ? const Color(0xFFC62828)
        : const Color(0xFF2A2A2A);
    _borderColor = widget.isError
        ? const Color(0x33000000)
        : const Color(0x26FFFFFF);
    _progressColor = widget.isError
        ? const Color(0x66FFFFFF)
        : widget.iconColor.withValues(alpha: 0.6);
    _iconCircleColor = widget.isError
        ? const Color(0x33FFFFFF)
        : widget.iconColor.withValues(alpha: 0.15);
    _iconDisplayColor = widget.isError ? Colors.white : widget.iconColor;
    _messageColor = widget.isError
        ? const Color(0xE6FFFFFF)
        : const Color(0xB3FFFFFF);
    _cardDecoration = BoxDecoration(
      color: _bgColor,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: _borderColor, width: 0.5),
      boxShadow: const [
        BoxShadow(
          color: Color(0x50000000),
          blurRadius: 30,
          offset: Offset(0, 8),
        ),
      ],
    );

    _slideController = AnimationController(
      duration: const Duration(milliseconds: 350),
      reverseDuration: const Duration(milliseconds: 250),
      vsync: this,
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _slideController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeIn,
    ));
    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _slideController, curve: Curves.easeOut),
    );

    _timerController = AnimationController(
      duration: widget.duration,
      vsync: this,
    );

    _springController = AnimationController(
      duration: const Duration(milliseconds: 350),
      vsync: this,
    );
    _springAnimation = const AlwaysStoppedAnimation(0.0);
    // Writes directly to the ValueNotifier — no setState needed.
    _springController.addListener(() {
      _dragOffset.value = _springAnimation.value;
    });

    _slideController.forward().then((_) {
      if (mounted) _timerController.forward();
    });
    _timerController.addStatusListener((status) {
      if (status == AnimationStatus.completed) _dismiss();
    });

    HapticFeedback.lightImpact();
  }

  void _dismiss() {
    if (!mounted || _dismissing) return;
    _dismissing = true;
    _springController.stop();
    _timerController.stop();
    _slideController.reverse().then((_) {
      if (mounted) widget.onDismissed();
    });
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (_dismissing) return;
    if (_springController.isAnimating) _springController.stop();
    _dragOffset.value = (_dragOffset.value + details.delta.dy).clamp(0.0, double.infinity);
    if (_timerController.isAnimating) _timerController.stop();
  }

  void _onDragEnd(DragEndDetails details) {
    if (_dismissing) return;
    final velocity = details.primaryVelocity ?? 0.0;
    if (_dragOffset.value >= _dismissThreshold || velocity >= _velocityThreshold) {
      _dismiss();
    } else {
      _springAnimation = Tween<double>(begin: _dragOffset.value, end: 0.0).animate(
        CurvedAnimation(parent: _springController, curve: Curves.easeOutCubic),
      );
      _springController.forward(from: 0.0).then((_) {
        if (mounted && !_dismissing) _timerController.forward();
      });
    }
  }

  @override
  void dispose() {
    _slideController.dispose();
    _timerController.dispose();
    _springController.dispose();
    _dragOffset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: Stack(
          children: [
            // Dark scrim — tap to dismiss
            Positioned.fill(
              child: GestureDetector(
                onTap: _dismiss,
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.6),
                ),
              ),
            ),
            // Toast card — only Transform rebuilds on drag via ValueListenableBuilder
            Positioned(
              bottom: widget.bottomPadding + 16,
              left: 24,
              right: 24,
              child: GestureDetector(
                onVerticalDragUpdate: _onDragUpdate,
                onVerticalDragEnd: _onDragEnd,
                child: ValueListenableBuilder<double>(
                  valueListenable: _dragOffset,
                  builder: (context, offset, child) {
                    return Transform.translate(
                      offset: Offset(0, offset),
                      child: child,
                    );
                  },
                  // child is built once and reused — never rebuilt during drag.
                  child: SlideTransition(
                    position: _slideAnimation,
                    child: RepaintBoundary(
                      child: Material(
                        color: Colors.transparent,
                        child: Container(
                          decoration: _cardDecoration,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Drag handle with timer progress
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: AnimatedBuilder(
                                  animation: _timerController,
                                  builder: (context, child) {
                                    return Container(
                                      width: 36,
                                      height: 4,
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                      clipBehavior: Clip.hardEdge,
                                      child: FractionallySizedBox(
                                        alignment: Alignment.centerLeft,
                                        widthFactor: 1.0 - _timerController.value,
                                        child: child,
                                      ),
                                    );
                                  },
                                  // Progress fill built once, reused every frame.
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: _progressColor,
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 24),
                              // Large centered icon
                              Container(
                                width: 72,
                                height: 72,
                                decoration: BoxDecoration(
                                  color: _iconCircleColor,
                                  shape: BoxShape.circle,
                                ),
                                alignment: Alignment.center,
                                child: Icon(
                                  widget.icon,
                                  size: 36,
                                  color: _iconDisplayColor,
                                ),
                              ),
                              const SizedBox(height: 20),
                              // Title
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 24),
                                child: Text(
                                  widget.title,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              // Message
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 24),
                                child: Text(
                                  widget.message,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: _messageColor,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 28),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
