import 'dart:async';

import 'package:flutter/material.dart';

import '../globals.dart' as globals;
import '../services/announcement.dart';
import '../services/announcements_service.dart';
import '../theme.dart';
import 'announcement_card.dart';

/// An announcement that slides down over the top of the screen: what a
/// push shows while the app is open, instead of a system notification.
///
/// It goes away after [_visibleFor], when swiped up, or once one of its
/// buttons or its X was tapped. Touching it keeps it up.
class AnnouncementBanner {
  AnnouncementBanner._();

  static OverlayEntry? _entry;
  static const _visibleFor = Duration(seconds: 12);

  /// Shows [item] over whatever screen is open, replacing a banner up.
  static void show(Announcement item, AnnouncementsService service) {
    final overlay = globals.navigatorKey.currentState?.overlay;
    if (overlay == null) return;
    hide();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _Banner(
        item: item,
        service: service,
        onGone: () {
          if (_entry == entry) _entry = null;
          if (entry.mounted) entry.remove();
        },
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }

  /// Removes the banner up, if any, at once.
  static void hide() {
    final entry = _entry;
    _entry = null;
    if (entry != null && entry.mounted) entry.remove();
  }
}

class _Banner extends StatefulWidget {
  const _Banner({
    required this.item,
    required this.service,
    required this.onGone,
  });

  final Announcement item;
  final AnnouncementsService service;
  final VoidCallback onGone;

  @override
  State<_Banner> createState() => _BannerState();
}

class _BannerState extends State<_Banner> with SingleTickerProviderStateMixin {
  late final AnimationController _slide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  )..forward();
  Timer? _autoHide;

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  @override
  void dispose() {
    _autoHide?.cancel();
    _slide.dispose();
    super.dispose();
  }

  void _scheduleHide() {
    _autoHide?.cancel();
    _autoHide = Timer(AnnouncementBanner._visibleFor, _hide);
  }

  Future<void> _hide() async {
    _autoHide?.cancel();
    if (!mounted) return;
    await _slide.reverse();
    widget.onGone();
  }

  void _onDragEnd(DragEndDetails details) {
    if ((details.primaryVelocity ?? 0) < -150) unawaited(_hide());
  }

  @override
  Widget build(BuildContext context) {
    final position = Tween(begin: const Offset(0, -1.2), end: Offset.zero)
        .animate(CurvedAnimation(
      parent: _slide,
      curve: Curves.fastOutSlowIn,
      reverseCurve: Curves.easeInOut,
    ));
    return Align(
      alignment: Alignment.topCenter,
      child: SlideTransition(
        position: position,
        child: SafeArea(
          bottom: false,
          child: Listener(
            onPointerDown: (_) => _autoHide?.cancel(),
            onPointerUp: (_) => _scheduleHide(),
            child: GestureDetector(
              onVerticalDragEnd: _onDragEnd,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    borderRadius: BorderRadius.all(Radius.circular(16)),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.announcementBannerShadow,
                        blurRadius: 24,
                        offset: Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Material(
                    type: MaterialType.transparency,
                    child: AnnouncementCard(
                      items: [widget.item],
                      settings: const AnnouncementSettings(autoplaySeconds: 0),
                      service: widget.service,
                      margin: EdgeInsets.zero,
                      onDone: () => unawaited(_hide()),
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
