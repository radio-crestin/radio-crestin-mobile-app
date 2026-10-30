import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../services/desktop_menu_service.dart';

/// Keeps what opens over the desktop shell (dialogs, panels, menus) clear
/// of the window's own buttons, which sit over the shell's top bar: the
/// top bar's height becomes padding at the top, as a phone's status bar
/// is. Dialogs then sit below it, their dim still covering the window.
///
/// The shell's own screen reads no padding: its top bar lays itself out
/// under the buttons (see [DesktopMenuService.titleBar]).
class DesktopTitleBarInset extends StatelessWidget {
  const DesktopTitleBarInset({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DesktopTitleBar>(
      valueListenable: DesktopMenuService.titleBar,
      child: child,
      builder: (context, titleBar, child) {
        if (!titleBar.hasWindowButtons) return child!;
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            padding: media.padding.copyWith(
              top: math.max(media.padding.top, titleBar.height),
            ),
            viewPadding: media.viewPadding.copyWith(
              top: math.max(media.viewPadding.top, titleBar.height),
            ),
          ),
          child: child!,
        );
      },
    );
  }
}
