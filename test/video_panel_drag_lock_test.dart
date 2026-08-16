import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sliding_up_panel2/sliding_up_panel2.dart';

/// Verifies the drag-lock used by the full player's video surfaces: wrapping
/// the media area in [IgnoreDraggableWidget] — as `PlaylistPlayerSection`'s
/// media surface and `FullAudioPlayer`'s TV video stage do — makes the sliding
/// panel ignore drags that START on the video (the pointer interacts with the
/// video instead), while drags anywhere else keep moving the panel.
void main() {
  const videoKey = ValueKey('video-surface');
  const plainKey = ValueKey('plain-area');

  Widget build(PanelController controller) {
    return MaterialApp(
      home: Scaffold(
        body: SlidingUpPanel(
          controller: controller,
          minHeight: 60,
          maxHeight: 400,
          defaultPanelState: PanelState.OPEN,
          panelBuilder: () => Column(
            children: [
              // Draggable header area (title, drag handle…).
              Container(key: plainKey, height: 120, color: Colors.grey),
              // Stand-in for the video surface, wrapped exactly like the app
              // wraps _MediaSurface / VideoPlayerStage.
              IgnoreDraggableWidget(
                child:
                    Container(key: videoKey, height: 180, color: Colors.black),
              ),
            ],
          ),
          body: const SizedBox.expand(),
        ),
      ),
    );
  }

  testWidgets('drag starting on the video surface does NOT move the panel',
      (tester) async {
    final controller = PanelController();
    await tester.pumpWidget(build(controller));
    await tester.pumpAndSettle();
    expect(controller.panelPosition, 1.0);

    // A firm downward drag from the video area — panel must stay open.
    await tester.drag(find.byKey(videoKey), const Offset(0, 250));
    await tester.pumpAndSettle();
    expect(controller.panelPosition, 1.0);
  });

  testWidgets(
      'the lock releases with the pointer: a later drag off the video '
      'still moves the panel', (tester) async {
    final controller = PanelController();
    await tester.pumpWidget(build(controller));
    await tester.pumpAndSettle();

    // Locked drag on the video first…
    await tester.drag(find.byKey(videoKey), const Offset(0, 250));
    await tester.pumpAndSettle();
    expect(controller.panelPosition, 1.0);

    // …then a drag from the plain area closes/moves the panel as usual.
    await tester.drag(find.byKey(plainKey), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(controller.panelPosition, lessThan(1.0));
  });
}
