import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme.dart';

/// The player's "mai mult" action: a menu above the button, right-aligned
/// with it, holding the song history and a YouTube search for the song.
///
/// iOS gets the native pull-down menu. Android gets a Material 3 menu, in the
/// wine of the player's sheets in the dark theme.
class PlayerMoreButton extends StatefulWidget {
  const PlayerMoreButton({
    super.key,
    required this.onHistory,
    required this.onYoutubeSearch,
    this.onOpened,
  });

  /// Opens the playing station's song history.
  final VoidCallback onHistory;

  /// Searches YouTube for the playing song. Null disables the item, for a
  /// station that hasn't named its song.
  final VoidCallback? onYoutubeSearch;

  /// Called each time the menu opens.
  final VoidCallback? onOpened;

  /// The menu items' labels.
  static const String historyLabel = 'Istoric melodii';
  static const String youtubeLabel = 'Caută pe YouTube';

  @override
  State<PlayerMoreButton> createState() => _PlayerMoreButtonState();
}

class _PlayerMoreButtonState extends State<PlayerMoreButton> {
  /// Width of the Android menu at the standard text size.
  static const double _materialMenuWidth = 232;

  /// Width of the Android menu, set ahead rather than fitted to the items:
  /// Material only lines a menu's leading edge up with its anchor, so the
  /// width is what lets the menu end where the button ends. It grows with the
  /// text size, up to the screen's width less its margins.
  double _materialMenuWidthFor(BuildContext context) {
    final grown = MediaQuery.textScalerOf(context).scale(_materialMenuWidth);
    final available = MediaQuery.sizeOf(context).width - 16;
    return grown.clamp(
      _materialMenuWidth,
      math.max(_materialMenuWidth, available),
    );
  }

  /// Whether the menu is open or opening: a tap on the button then closes
  /// the menu rather than opening it again.
  bool _isOpen = false;

  void _setOpen(bool isOpen) {
    if (!mounted || isOpen == _isOpen) return;
    setState(() => _isOpen = isOpen);
  }

  void _toggle(MenuController controller) {
    if (_isOpen) {
      controller.close();
      return;
    }
    controller.open();
    widget.onOpened?.call();
  }

  @override
  Widget build(BuildContext context) {
    final isApple = switch (Theme.of(context).platform) {
      TargetPlatform.iOS || TargetPlatform.macOS => true,
      _ => false,
    };
    return isApple ? _buildCupertinoMenu() : _buildMaterialMenu(context);
  }

  /// The iOS pull-down menu. Near the bottom-right of the screen it opens
  /// upward with its trailing edge on the button's, as UIKit's does.
  Widget _buildCupertinoMenu() {
    return CupertinoMenuAnchor(
      consumeOutsideTaps: true,
      onAnimationStatusChanged: (status) =>
          _setOpen(status.isForwardOrCompleted),
      menuChildren: [
        CupertinoMenuItem(
          trailing: const Icon(CupertinoIcons.clock),
          onPressed: widget.onHistory,
          child: const Text(PlayerMoreButton.historyLabel),
        ),
        CupertinoMenuItem(
          trailing: const Icon(CupertinoIcons.play_rectangle),
          onPressed: widget.onYoutubeSearch,
          child: const Text(PlayerMoreButton.youtubeLabel),
        ),
      ],
      builder: (context, controller, _) => _MoreFace(
        isOpen: _isOpen,
        onTap: () => _toggle(controller),
      ),
    );
  }

  /// The Android menu. It drops from under the button's trailing edge, and
  /// with no room below (the portrait player) Material flips it above.
  Widget _buildMaterialMenu(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final width = _materialMenuWidthFor(context);
    return MenuAnchor(
      consumeOutsideTap: true,
      // Keeps the items to the menu's width; a label too long for it wraps.
      crossAxisUnconstrained: false,
      onOpen: () => _setOpen(true),
      onClose: () => _setOpen(false),
      alignmentOffset: Offset(-width, 0),
      style: MenuStyle(
        alignment: AlignmentDirectional.bottomEnd,
        fixedSize: WidgetStatePropertyAll(Size.fromWidth(width)),
        backgroundColor: isDark
            ? const WidgetStatePropertyAll(AppColors.darkPlayerMenu)
            : null,
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 8),
        ),
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
        ),
      ),
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Icons.history),
          onPressed: widget.onHistory,
          child: const Text(PlayerMoreButton.historyLabel),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.video_library_outlined),
          onPressed: widget.onYoutubeSearch,
          child: const Text(PlayerMoreButton.youtubeLabel),
        ),
      ],
      builder: (context, controller, _) => _MoreFace(
        isOpen: _isOpen,
        onTap: () => _toggle(controller),
      ),
    );
  }
}

/// The button itself: the "…" icon over its "mai mult" label, like the
/// player's other actions. It keeps its color while the menu is open, as
/// UIKit's and Material's menu buttons do: the menu above it is the
/// feedback, and a tint on the wine panel would barely show.
class _MoreFace extends StatelessWidget {
  const _MoreFace({required this.isOpen, required this.onTap});

  final bool isOpen;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      expanded: isOpen,
      label: 'Mai multe opțiuni',
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.more_horiz,
                size: 24,
                color: theme.colorScheme.onSurface,
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    'mai mult',
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: theme.textSecondary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
