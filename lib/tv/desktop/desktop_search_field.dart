import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tv_theme.dart';

/// The search field in the desktop top bar: stations by name, or by the
/// song they play, as the phone's search finds them.
///
/// ↑ and ↓ move the highlight through the results ([onMoveHighlight]),
/// Enter plays the highlighted one ([onSubmitted]) and Esc ends the search
/// ([onCancel]).
class DesktopSearchField extends StatefulWidget {
  const DesktopSearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onSubmitted,
    required this.onMoveHighlight,
    required this.onCancel,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmitted;

  /// Moves the results' highlight one place down, or up.
  final void Function({required bool down}) onMoveHighlight;

  /// Clears the field and gives the keyboard back to the screen.
  final VoidCallback onCancel;

  static const String hint = 'Caută stații sau melodii';

  static const double height = 36;

  @override
  State<DesktopSearchField> createState() => _DesktopSearchFieldState();
}

class _DesktopSearchFieldState extends State<DesktopSearchField> {
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(DesktopSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChanged);
      widget.focusNode.addListener(_onFocusChanged);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChanged);
    super.dispose();
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      widget.onMoveHighlight(down: true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      widget.onMoveHighlight(down: false);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape && event is KeyDownEvent) {
      widget.onCancel();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final focused = widget.focusNode.hasFocus;
    final shape = BorderRadius.circular(DesktopSearchField.height / 2);
    const iconBox = BoxConstraints(
      minWidth: DesktopSearchField.height,
      minHeight: DesktopSearchField.height,
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: SizedBox(
          height: DesktopSearchField.height,
          child: TextField(
            controller: widget.controller,
            focusNode: widget.focusNode,
            onChanged: widget.onChanged,
            // Enter keeps the focus in the field, for the listener to try
            // the next result or another search.
            onEditingComplete: () {},
            onSubmitted: (_) => widget.onSubmitted(),
            textInputAction: TextInputAction.search,
            autocorrect: false,
            enableSuggestions: false,
            cursorColor: TvColors.primary,
            textAlignVertical: TextAlignVertical.center,
            style: const TextStyle(fontSize: 14, color: TvColors.textPrimary),
            decoration: InputDecoration(
              hintText: DesktopSearchField.hint,
              hintStyle: const TextStyle(
                fontSize: 14,
                color: TvColors.textTertiary,
              ),
              prefixIcon: const Icon(
                Icons.search_rounded,
                size: 19,
                color: TvColors.textTertiary,
              ),
              prefixIconConstraints: iconBox,
              suffixIcon: _Suffix(
                controller: widget.controller,
                focused: focused,
                onClear: () {
                  // Empty, the x leaves the field, as Esc does.
                  if (widget.controller.text.isEmpty) {
                    widget.focusNode.unfocus();
                    return;
                  }
                  widget.controller.clear();
                  widget.onChanged('');
                  widget.focusNode.requestFocus();
                },
              ),
              suffixIconConstraints: iconBox,
              isDense: true,
              contentPadding: EdgeInsets.zero,
              filled: true,
              fillColor: focused || _hovered
                  ? DesktopTokens.controlHoverFill
                  : DesktopTokens.controlFill,
              hoverColor: Colors.transparent,
              border: OutlineInputBorder(
                borderRadius: shape,
                borderSide: const BorderSide(color: DesktopTokens.hairline),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: shape,
                borderSide: const BorderSide(color: DesktopTokens.hairline),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: shape,
                borderSide: const BorderSide(
                  color: TvColors.primary,
                  width: 1.5,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The end of the field: an x that clears the text, or with none, leaves
/// the field. The field only shows once opened, so its shortcut isn't
/// spelled out in it.
class _Suffix extends StatelessWidget {
  const _Suffix({
    required this.controller,
    required this.focused,
    required this.onClear,
  });

  final TextEditingController controller;
  final bool focused;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final Widget child;
        // With text the x clears it; empty but focused, it leaves the field.
        if (value.text.isNotEmpty || focused) {
          // No tooltip: "Esc închide căutarea" is spelled out right under
          // the field, where a tooltip would cover it.
          child = Padding(
            key: const ValueKey('clear'),
            padding: const EdgeInsetsDirectional.only(end: 6),
            child: IconButton(
              onPressed: onClear,
              iconSize: 16,
              style: IconButton.styleFrom(
                fixedSize: const Size.square(28),
                minimumSize: const Size.square(28),
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                backgroundColor: DesktopTokens.controlHoverFill,
                foregroundColor: TvColors.textPrimary,
                hoverColor: Colors.white.withValues(alpha: 0.12),
              ),
              icon: Icon(
                Icons.close_rounded,
                semanticLabel: value.text.isNotEmpty
                    ? 'Șterge textul'
                    : 'Închide căutarea',
              ),
            ),
          );
        } else {
          child = const SizedBox.shrink(key: ValueKey('none'));
        }
        return AnimatedSwitcher(
          duration: DesktopTokens.hoverDuration,
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.centerRight,
            children: [...previous, if (current != null) current],
          ),
          child: child,
        );
      },
    );
  }
}
