import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/posthog_screen_observer.dart';
import '../tv_theme.dart';
import 'now_playing_controls.dart';

/// Shows Settings on desktop: a panel centered over the window, at most
/// [DesktopSettingsPanel.maxWidth] wide, with a close button, instead of a
/// page filling the window as on a phone.
///
/// [home] builds the first page. The pages it opens (hidden stations,
/// logs) slide in inside the panel, with a back button; Esc goes back a
/// page, and from the first one closes the panel, as a click outside it
/// does. Opening Settings while the panel is up does nothing more.
Future<void> showDesktopSettingsPanel(
  BuildContext context, {
  required WidgetBuilder home,
}) async {
  if (DesktopSettingsPanel._open != null) return;
  final token = Object();
  DesktopSettingsPanel._open = token;
  try {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (dialogContext) => DesktopSettingsPanel(
        home: home,
        onClose: () => Navigator.of(dialogContext).pop(),
        openToken: token,
      ),
    );
  } finally {
    DesktopSettingsPanel._release(token);
  }
}

/// The desktop Settings panel: a dark rounded card holding its own
/// navigator, so the pages Settings opens stay inside it, and its own
/// messenger, so their snack bars show in it rather than under the dim.
class DesktopSettingsPanel extends StatefulWidget {
  const DesktopSettingsPanel({
    super.key,
    required this.home,
    required this.onClose,
    this.openToken,
  });

  /// Builds the panel's first page.
  final WidgetBuilder home;

  /// Closes the whole panel.
  final VoidCallback onClose;

  /// Marks this panel as the one up (see [showDesktopSettingsPanel]).
  final Object? openToken;

  /// The panel's largest size; a smaller window gets a smaller panel.
  static const double maxWidth = 680;
  static const double maxHeight = 880;

  /// The token of the panel up, so a second "Setări" doesn't stack
  /// another; null when none is.
  static Object? _open;

  /// Lets another panel open once the one of [token] is gone: popped, or
  /// taken down with the window's navigator.
  static void _release(Object? token) {
    if (token != null && identical(_open, token)) _open = null;
  }

  /// Goes back in the panel that is up, as Esc does: closes its open menu,
  /// or goes back a page, or closes it. For the browser-style back (the
  /// mouse's back button, ⌘[). Null when no panel is up; otherwise whether
  /// it closed the panel.
  static bool? goBack() => _escape?.call();

  /// The Esc of the panel that is up.
  static bool Function()? _escape;

  @override
  State<DesktopSettingsPanel> createState() => _DesktopSettingsPanelState();
}

class _DesktopSettingsPanelState extends State<DesktopSettingsPanel> {
  final GlobalKey<NavigatorState> _navigator = GlobalKey();

  /// Records the panel's pages in PostHog, as the app's navigator does
  /// for the phone's pages.
  final PosthogScreenObserver _screens = PosthogScreenObserver();

  @override
  void initState() {
    super.initState();
    DesktopSettingsPanel._escape = _escape;
  }

  @override
  void dispose() {
    DesktopSettingsPanel._release(widget.openToken);
    if (DesktopSettingsPanel._escape == _escape) {
      DesktopSettingsPanel._escape = null;
    }
    super.dispose();
  }

  /// Esc: closes the menu or dropdown the keyboard is in, or goes back a
  /// page, or from the first one, closes the panel. Says whether it closed
  /// the panel.
  bool _escape() {
    if (_dismissFocusedPopup()) return false;
    final navigator = _navigator.currentState;
    if (navigator != null && navigator.canPop()) {
      navigator.pop();
      return false;
    }
    widget.onClose();
    return true;
  }

  /// Takes Esc for the panel's pages, which as full pages ignore it.
  ///
  /// What has the keyboard gets it first: an open menu or dropdown closes
  /// on its own. Only then does Esc go back a page, or close the panel.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    _escape();
    return KeyEventResult.handled;
  }

  /// Dismisses the menu or popup the keyboard focus is in, if it is in
  /// one; says whether it was.
  ///
  /// The nearest dismiss action decides, as for the app's own Esc: an open
  /// menu's, a dropdown's, or a page's, which is never enabled.
  static bool _dismissFocusedPopup() {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) return false;
    const intent = DismissIntent();
    final action = Actions.maybeFind<DismissIntent>(focused, intent: intent);
    if (action == null) return false;
    final (enabled, _) =
        Actions.of(focused).invokeActionIfEnabled(action, intent, focused);
    return enabled;
  }

  @override
  Widget build(BuildContext context) {
    final window = MediaQuery.sizeOf(context);
    const radius = BorderRadius.all(Radius.circular(16));
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: DesktopSettingsPanel.maxWidth,
        height: math.max(
          0.0,
          math.min(DesktopSettingsPanel.maxHeight, window.height - 48),
        ),
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: NowPlayingPalette.edge),
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: DesktopSettingsScope(
              close: widget.onClose,
              child: ScaffoldMessenger(
                child: Focus(
                  canRequestFocus: false,
                  skipTraversal: true,
                  onKeyEvent: _onKey,
                  child: Navigator(
                    key: _navigator,
                    observers: [_screens],
                    onGenerateRoute: (_) => MaterialPageRoute<void>(
                      // Named so PostHog records a `$screen` for it.
                      settings: const RouteSettings(name: '/settings'),
                      builder: widget.home,
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

/// Lets a page inside the desktop Settings panel close the whole panel.
class DesktopSettingsScope extends InheritedWidget {
  const DesktopSettingsScope({
    super.key,
    required this.close,
    required super.child,
  });

  /// Closes the panel.
  final VoidCallback close;

  /// The panel [context] is in, or null outside of one.
  static DesktopSettingsScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<DesktopSettingsScope>();

  @override
  bool updateShouldNotify(DesktopSettingsScope oldWidget) =>
      close != oldWidget.close;
}

/// A page of the desktop Settings panel: [title] in a bar with a back
/// button (when there is a page to go back to) and a close button, over
/// [child].
class DesktopSettingsFrame extends StatelessWidget {
  const DesktopSettingsFrame({
    super.key,
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _DesktopSettingsHeader(title: title),
        Expanded(child: child),
      ],
    );
  }
}

class _DesktopSettingsHeader extends StatelessWidget {
  const _DesktopSettingsHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final canGoBack = Navigator.of(context).canPop();
    final scope = DesktopSettingsScope.maybeOf(context);
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: TvColors.divider, width: 0.5),
        ),
      ),
      child: NavigationToolbar(
        leading: canGoBack
            ? Center(
                widthFactor: 1,
                child: DesktopActionButton(
                  icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 16),
                  label: const SizedBox.shrink(),
                  tooltip: 'Înapoi (Esc)',
                  labeled: false,
                  size: 34,
                  accent: TvColors.textSecondary,
                  onPressed: () => Navigator.maybePop(context),
                ),
              )
            : null,
        middle: Semantics(
          header: true,
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
              color: TvColors.textPrimary,
            ),
          ),
        ),
        trailing: Center(
          widthFactor: 1,
          child: DesktopActionButton(
            icon: const Icon(Icons.close_rounded, size: 18),
            label: const SizedBox.shrink(),
            tooltip: canGoBack ? 'Închide setările' : 'Închide (Esc)',
            labeled: false,
            size: 34,
            accent: TvColors.textSecondary,
            onPressed: scope?.close ?? () => Navigator.maybePop(context),
          ),
        ),
      ),
    );
  }
}
