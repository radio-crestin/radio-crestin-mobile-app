import 'package:flutter/widgets.dart';

/// Lays [child] out as if the keyboard were closed.
///
/// For a page with no text field of its own, under a dialog that has one:
/// the dialog's keyboard reaches the page too. The page's scaffold shrinks
/// above it, and the navigation bar leaves the bottom padding (up to
/// Android 10 also the view padding) while the keyboard covers it. Home's
/// list ends with that padding, so it scrolled when the search dialog
/// opened and again when it closed.
///
/// Routes pushed from [child] are built by the navigator, above this
/// widget, so dialogs and sheets still make room for the keyboard.
class KeyboardFreeMediaQuery extends StatefulWidget {
  const KeyboardFreeMediaQuery({super.key, required this.child});

  final Widget child;

  @override
  State<KeyboardFreeMediaQuery> createState() =>
      _KeyboardFreeMediaQueryState();
}

class _KeyboardFreeMediaQueryState extends State<KeyboardFreeMediaQuery> {
  /// The bottom padding and view padding from before the keyboard opened.
  (double, double)? _bottomWithoutKeyboard;

  late MediaQueryData _data;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final media = MediaQuery.of(context);
    if (media.viewInsets.bottom == 0 || _bottomWithoutKeyboard == null) {
      _bottomWithoutKeyboard = (media.padding.bottom, media.viewPadding.bottom);
    }
    final (padding, viewPadding) = _bottomWithoutKeyboard!;
    // The same data on every frame of the keyboard's animation, so nothing
    // under it rebuilds.
    _data = media.copyWith(
      viewInsets: media.viewInsets.copyWith(bottom: 0),
      padding: media.padding.copyWith(bottom: padding),
      viewPadding: media.viewPadding.copyWith(bottom: viewPadding),
    );
  }

  @override
  Widget build(BuildContext context) =>
      MediaQuery(data: _data, child: widget.child);
}
