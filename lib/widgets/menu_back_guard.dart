import 'dart:async';

import 'package:flutter/widgets.dart';

/// Holds BACK back while a menu drawn over the page is open, and closes the
/// menu instead: the menu isn't a page of its own, so BACK would otherwise
/// leave the page, or the app, with it still open.
///
/// It joins the page only while its menu is open. A [PopScope] around each
/// menu would do the same, but every one of them tells Android how BACK is
/// handled as its row is built or dropped, which a list of rows does on
/// almost every frame of a fling.
///
/// The menu's state sets [route] from `didChangeDependencies`, [open] as
/// its menu opens and closes, and calls [dispose] from its own.
class MenuBackGuard extends PopEntry<Object?> {
  MenuBackGuard({required this.onBack});

  /// Closes the menu, for a BACK held back while it was open.
  final VoidCallback onBack;

  ModalRoute<Object?>? _route;
  bool _open = false;

  @override
  final ValueNotifier<bool> canPopNotifier = ValueNotifier(false);

  /// The page the menu is on.
  set route(ModalRoute<Object?>? route) {
    if (route == _route) return;
    _leave();
    _route = route;
    _join();
  }

  /// Whether the menu is open, from the moment it starts opening until it
  /// starts closing.
  set open(bool open) {
    if (open == _open) return;
    _leave();
    _open = open;
    _join();
  }

  void _join() {
    if (_open) _route?.registerPopEntry(this);
  }

  void _leave() {
    if (_open) _route?.unregisterPopEntry(this);
  }

  void dispose() {
    _leave();
    _route = null;
    canPopNotifier.dispose();
  }

  /// Closes the menu just after the page has told all its guards, since
  /// the menu closing at once takes this guard off the page they are
  /// being told from.
  @override
  void onPopInvokedWithResult(bool didPop, Object? result) {
    if (!didPop) scheduleMicrotask(onBack);
  }
}
