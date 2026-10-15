# Vendored fork of `sliding_up_panel2` 3.3.0+1

This is a local copy of [`sliding_up_panel2` 3.3.0+1](https://pub.dev/packages/sliding_up_panel2)
(the latest release, published May 2023), vendored as a path dependency so we
can patch how the panel handles a cancelled touch. Upstream's `example/` and
`test/` folders are left out.

## Why

The panel follows the finger through a raw `Listener` that handled only
pointer down, move and up. iOS can take a touch away in the middle of a drag:
a swipe that starts on the mini player at the bottom edge and turns into the
home / app switcher gesture, or an incoming call. Flutter then sends a
`PointerCancelEvent` instead of a `PointerUpEvent`. The panel ignored it, so
it never settled and stayed stranded where the finger left it, half open with
the mini player faded over the full player. It stayed that way after the app
came back to the foreground, until the next touch on the panel.

Reproduced on the iOS simulator with real clicks: holding the bottom edge for
~0.8 s, then swiping up, delivers Down, Move, then Cancel, and the app goes to
the background with the panel left at that position.

## The patch — `lib/src/panel.dart`

`_gestureHandler`'s `Listener` gets an `onPointerCancel` that resets the drag
axis and calls `_onGestureEnd(Velocity.zero)`: the same settle as lifting the
finger without a fling, so the panel goes to the nearer of closed / open. The
touch's velocity is ignored because its last motion belongs to the system
gesture; with it, every home swipe started on the mini player would fling the
full player open.

Covered by `test/sliding_panel_cancel_test.dart` in the app.

## Upgrading

If bumping `sliding_up_panel2`, re-apply the `onPointerCancel` handler (or
confirm upstream handles `PointerCancelEvent`) before replacing this folder.
