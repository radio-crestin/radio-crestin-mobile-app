import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/desktop_menu_service.dart';
import 'package:radio_crestin/tv/desktop/desktop_shortcuts.dart';

/// Records the command each key down asks for, as the desktop shell's
/// focus scope does.
class _Recorder extends StatelessWidget {
  const _Recorder({
    required this.commands,
    this.editingText = false,
    this.focusActivates = false,
  });

  final List<DesktopCommand?> commands;
  final bool editingText;
  final bool focusActivates;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          commands.add(DesktopShortcuts.commandFor(
            event,
            editingText: editingText,
            focusActivates: focusActivates,
            commandKey: true,
          ));
        }
        return KeyEventResult.handled;
      },
      child: const SizedBox.expand(),
    );
  }
}

Future<List<DesktopCommand?>> _press(
  WidgetTester tester,
  Future<void> Function() keys, {
  bool editingText = false,
  bool focusActivates = false,
}) async {
  final commands = <DesktopCommand?>[];
  await tester.pumpWidget(MaterialApp(
    home: _Recorder(
      commands: commands,
      editingText: editingText,
      focusActivates: focusActivates,
    ),
  ));
  await tester.pump();
  await keys();
  return commands;
}

Future<void> _command(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
}

void main() {
  testWidgets('Space plays and pauses', (tester) async {
    final commands = await _press(
      tester,
      () => tester.sendKeyEvent(LogicalKeyboardKey.space),
    );
    expect(commands, [DesktopCommand.playPause]);
  });

  testWidgets('the menu bar\'s shortcuts ask for its commands',
      (tester) async {
    final commands = await _press(tester, () async {
      await _command(tester, LogicalKeyboardKey.keyF);
      await _command(tester, LogicalKeyboardKey.keyK);
      await _command(tester, LogicalKeyboardKey.arrowRight);
      await _command(tester, LogicalKeyboardKey.arrowLeft);
      await _command(tester, LogicalKeyboardKey.keyD);
      await _command(tester, LogicalKeyboardKey.digit0);
      await _command(tester, LogicalKeyboardKey.comma);
      await _command(tester, LogicalKeyboardKey.bracketLeft);
      await _command(tester, LogicalKeyboardKey.bracketRight);
    });
    expect(commands.whereType<DesktopCommand>(), [
      DesktopCommand.search,
      DesktopCommand.search,
      DesktopCommand.next,
      DesktopCommand.previous,
      DesktopCommand.toggleFavorite,
      DesktopCommand.nowPlaying,
      DesktopCommand.settings,
      DesktopCommand.back,
      DesktopCommand.forward,
    ]);
  });

  testWidgets('M mutes and unmutes; ⌘M and ⇧M are no shortcut',
      (tester) async {
    final commands = await _press(tester, () async {
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      // ⌘M minimizes the window, from the menu bar.
      await _command(tester, LogicalKeyboardKey.keyM);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    });
    expect(commands.whereType<DesktopCommand>(), [DesktopCommand.toggleMute]);
  });

  testWidgets('"/" opens the search', (tester) async {
    final commands = await _press(
      tester,
      () => tester.sendKeyEvent(
        LogicalKeyboardKey.slash,
        character: '/',
      ),
    );
    expect(commands, [DesktopCommand.search]);
  });

  testWidgets('a text field keeps Space, "/", F, M and ⌘←/⌘→, not ⌘F',
      (tester) async {
    final commands = await _press(
      tester,
      editingText: true,
      () async {
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '/');
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
        await _command(tester, LogicalKeyboardKey.arrowRight);
        await _command(tester, LogicalKeyboardKey.arrowLeft);
        await _command(tester, LogicalKeyboardKey.keyF);
      },
    );
    expect(commands.whereType<DesktopCommand>(), [DesktopCommand.search]);
  });

  testWidgets('a focused button keeps Space', (tester) async {
    final commands = await _press(
      tester,
      focusActivates: true,
      () => tester.sendKeyEvent(LogicalKeyboardKey.space),
    );
    expect(commands, [null]);
  });

  testWidgets('F adds the playing station to the favorites or removes it, '
      'as ⌘D does; ⇧F is no shortcut', (tester) async {
    final commands = await _press(tester, () async {
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    });
    expect(
      commands.whereType<DesktopCommand>(),
      [DesktopCommand.toggleFavorite],
    );
  });

  testWidgets('other plain letters and arrows are no shortcut',
      (tester) async {
    final commands = await _press(tester, () async {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    });
    expect(commands.whereType<DesktopCommand>(), isEmpty);
  });
}
