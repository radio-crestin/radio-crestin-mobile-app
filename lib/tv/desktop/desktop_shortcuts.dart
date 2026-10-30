import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../services/desktop_menu_service.dart';

/// The desktop browse screen's keyboard shortcuts and the hints that name
/// them in tooltips.
///
/// Every shortcut stands for a [DesktopCommand], which the screen hands to
/// [DesktopMenuService.dispatch], so a key and the menu item it names
/// always do the same thing. "⌘" is Ctrl off macOS.
class DesktopShortcuts {
  DesktopShortcuts._();

  /// Whether "⌘" is the Command key, as on macOS, rather than Ctrl.
  static bool get usesCommandKey => !kIsWeb && Platform.isMacOS;

  static String get _command => usesCommandKey ? '⌘' : 'Ctrl+';

  /// Hint for play/pause.
  static const String playPauseHint = 'Spațiu';

  /// Hint for the next station.
  static String get nextHint => '$_command→';

  /// Hint for the previous station.
  static String get previousHint => '$_command←';

  /// Hint for the search field.
  static String get searchHint => '${_command}F';

  /// Hint for adding the playing station to the favorites, or removing it:
  /// F, as in "Se redă acum" (the menu bar's ⌘D does it too).
  static const String favoriteHint = 'F';

  /// Hint for opening "Se redă acum".
  static String get nowPlayingHint => '${_command}0';

  /// Hint for Settings.
  static String get settingsHint => '$_command,';

  /// Hints for turning the volume up and down.
  static String get volumeUpHint => '$_command↑';
  static String get volumeDownHint => '$_command↓';

  /// Hint for muting and unmuting.
  static const String muteHint = 'M';

  /// The command [event] asks for, or null when it is none of the screen's
  /// shortcuts.
  ///
  /// The keys match the menu bar's: ⌘F (and ⌘K, "/") search, ⌘, Settings,
  /// ⌘→ and ⌘← the next and previous station, ⌘D the favorite, ⌘0 "Se
  /// redă acum"; Space plays and pauses, F adds the playing station to the
  /// favorites or removes it, M mutes and unmutes.
  ///
  /// [editingText]: whether a text field has the keyboard focus. It keeps
  /// the keys it types and moves its caret with (Space, "/", F, M, the
  /// arrows with ⌘);
  /// the other shortcuts still work in it. [focusActivates]: whether the
  /// focused control takes Space itself, as a button does when the
  /// keyboard moved to it.
  static DesktopCommand? commandFor(
    KeyEvent event, {
    required bool editingText,
    required bool focusActivates,
    bool? commandKey,
    HardwareKeyboard? keyboard,
  }) {
    if (event is! KeyDownEvent) return null;
    final state = keyboard ?? HardwareKeyboard.instance;
    final meta = commandKey ?? usesCommandKey;
    bool accepts(LogicalKeyboardKey key, {bool command = false}) =>
        SingleActivator(
          key,
          meta: command && meta,
          control: command && !meta,
        ).accepts(event, state);

    if (accepts(LogicalKeyboardKey.keyF, command: true) ||
        accepts(LogicalKeyboardKey.keyK, command: true)) {
      return DesktopCommand.search;
    }
    if (accepts(LogicalKeyboardKey.comma, command: true)) {
      return DesktopCommand.settings;
    }
    if (accepts(LogicalKeyboardKey.keyD, command: true)) {
      return DesktopCommand.toggleFavorite;
    }
    if (accepts(LogicalKeyboardKey.digit0, command: true)) {
      return DesktopCommand.nowPlaying;
    }
    if (accepts(LogicalKeyboardKey.bracketLeft, command: true)) {
      return DesktopCommand.back;
    }
    if (accepts(LogicalKeyboardKey.bracketRight, command: true)) {
      return DesktopCommand.forward;
    }
    if (editingText) return null;
    if (accepts(LogicalKeyboardKey.arrowRight, command: true)) {
      return DesktopCommand.next;
    }
    if (accepts(LogicalKeyboardKey.arrowLeft, command: true)) {
      return DesktopCommand.previous;
    }
    if (accepts(LogicalKeyboardKey.arrowUp, command: true)) {
      return DesktopCommand.volumeUp;
    }
    if (accepts(LogicalKeyboardKey.arrowDown, command: true)) {
      return DesktopCommand.volumeDown;
    }
    if (const CharacterActivator('/').accepts(event, state)) {
      return DesktopCommand.search;
    }
    if (!focusActivates && accepts(LogicalKeyboardKey.space)) {
      return DesktopCommand.playPause;
    }
    if (accepts(LogicalKeyboardKey.keyF)) {
      return DesktopCommand.toggleFavorite;
    }
    if (accepts(LogicalKeyboardKey.keyM)) return DesktopCommand.toggleMute;
    return null;
  }

  /// Whether the keyboard focus is in a text field.
  static bool get isEditingText {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    return context.widget is EditableText ||
        context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  /// Whether the focused control, other than [ignoring], activates on
  /// Space: a button or a menu item the keyboard moved to. A station card
  /// takes only Return, so Space still plays and pauses there.
  static bool focusActivates({FocusNode? ignoring}) {
    final node = FocusManager.instance.primaryFocus;
    final context = node?.context;
    if (node == null || node == ignoring || context == null) return false;
    return Actions.maybeFind<ActivateIntent>(context) != null;
  }
}
