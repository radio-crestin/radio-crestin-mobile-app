import 'dart:ui';

import 'package:flutter/material.dart';

/// Shows a frosted-glass toast that slides in from the top of the screen.
/// Swipe up to dismiss early. Auto-dismisses after [duration].
///
/// Returns the [OverlayEntry] so callers can remove it if needed
/// (e.g. to replace with a new toast).
OverlayEntry showTopToast(
  BuildContext context, {
  required String title,
  required String message,
  IconData icon = Icons.check_circle_rounded,
  Duration duration = const Duration(seconds: 4),
  VoidCallback? onDismissed,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final topPadding = MediaQuery.of(context).padding.top;
  bool removed = false;

  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => _TopToastWidget(
      title: title,
      message: message,
      icon: icon,
      isDark: isDark,
      topPadding: topPadding,
      duration: duration,
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

/// Safely removes an [OverlayEntry] returned by [showTopToast].
/// No-op if already removed.
void removeTopToast(OverlayEntry? entry) {
  if (entry == null) return;
  try {
    entry.remove();
  } catch (_) {
    // Already removed (auto-dismissed or swiped away)
  }
}

class _TopToastWidget extends StatefulWidget {
  final String title;
  final String message;
  final IconData icon;
  final bool isDark;
  final double topPadding;
  final Duration duration;
  final VoidCallback onDismissed;

  const _TopToastWidget({
    required this.title,
    required this.message,
    required this.icon,
    required this.isDark,
    required this.topPadding,
    required this.duration,
    required this.onDismissed,
  });

  @override
  State<_TopToastWidget> createState() => _TopToastWidgetState();
}

class _TopToastWidgetState extends State<_TopToastWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slideAnimation;
  late final Animation<double> _fadeAnimation;
  double _dragOffset = 0;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 350),
      reverseDuration: const Duration(milliseconds: 250),
      vsync: this,
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeIn,
    ));
    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );

    _controller.forward();
    Future.delayed(widget.duration, _dismiss);
  }

  void _dismiss() {
    if (!mounted || _dismissing) return;
    _dismissing = true;
    _controller.reverse().then((_) {
      if (mounted) widget.onDismissed();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: widget.topPadding + 8,
      left: 16,
      right: 16,
      child: GestureDetector(
        onVerticalDragUpdate: (details) {
          if (details.delta.dy < 0) {
            setState(() {
              _dragOffset += details.delta.dy;
            });
          }
        },
        onVerticalDragEnd: (details) {
          if (_dragOffset < -30 || details.primaryVelocity != null && details.primaryVelocity! < -200) {
            _dismiss();
          } else {
            setState(() {
              _dragOffset = 0;
            });
          }
        },
        child: Transform.translate(
          offset: Offset(0, _dragOffset.clamp(-100, 0)),
          child: Opacity(
            opacity: (1.0 + _dragOffset / 100).clamp(0.0, 1.0),
            child: SlideTransition(
              position: _slideAnimation,
              child: FadeTransition(
                opacity: _fadeAnimation,
                child: Material(
                  color: Colors.transparent,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          color: widget.isDark
                              ? Colors.white.withValues(alpha: 0.12)
                              : Colors.black.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: widget.isDark
                                ? Colors.white.withValues(alpha: 0.15)
                                : Colors.black.withValues(alpha: 0.08),
                            width: 0.5,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: const Color(0xFF34C759).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              alignment: Alignment.center,
                              child: Icon(
                                widget.icon,
                                size: 20,
                                color: const Color(0xFF34C759),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    widget.title,
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: widget.isDark ? Colors.white : const Color(0xFF1C1C1E),
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    widget.message,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: widget.isDark
                                          ? Colors.white.withValues(alpha: 0.7)
                                          : Colors.black.withValues(alpha: 0.55),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
