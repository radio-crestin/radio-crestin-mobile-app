import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/tv/desktop/desktop_now_playing_route.dart';

/// Counts the times it paints; [ticks] asks it to paint again, as a
/// spinner or the equalizer does every frame.
class _CountingPainter extends CustomPainter {
  _CountingPainter(this.ticks) : super(repaint: ticks);

  final ValueNotifier<int> ticks;
  int paints = 0;

  @override
  void paint(Canvas canvas, Size size) {
    paints++;
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.teal);
  }

  @override
  bool shouldRepaint(_CountingPainter oldDelegate) => false;
}

/// A platform view, as a web page shows in, which can't be drawn into an
/// image.
class _FakePlatformView extends LeafRenderObjectWidget {
  const _FakePlatformView();

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFakePlatformView();
}

class _RenderFakePlatformView extends RenderBox {
  @override
  bool get sizedByParent => true;

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void paint(PaintingContext context, Offset offset) =>
      context.addLayer(PlatformViewLayer(rect: offset & size, viewId: 1));
}

void main() {
  late ValueNotifier<int> ticks;
  late _CountingPainter painter;

  setUp(() {
    ticks = ValueNotifier(0);
    painter = _CountingPainter(ticks);
  });

  tearDown(() => ticks.dispose());

  /// Shows a window whose "open" button opens the panel with [content]
  /// over a painter that counts its paints.
  Future<void> pumpScreen(WidgetTester tester, {Widget? content}) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).push(
              DesktopNowPlayingRoute(
                builder: (_) => Stack(
                  fit: StackFit.expand,
                  children: [
                    CustomPaint(painter: painter),
                    if (content != null) content,
                  ],
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
  }

  /// Pumps [frames] frames 10 ms apart, the content asking each to paint
  /// again; returns how many times it painted.
  Future<int> pumpFrames(WidgetTester tester, int frames) async {
    final before = painter.paints;
    for (var i = 0; i < frames; i++) {
      ticks.value++;
      await tester.pump(const Duration(milliseconds: 10));
    }
    return painter.paints - before;
  }

  /// The opacity layers drawn in the window that fade what they hold.
  ///
  /// The panel's surface has one too, fading over the bar only while the
  /// panel is barely taller than it; it is opaque in the checks below.
  Iterable<OpacityLayer> fadingLayers(WidgetTester tester) => tester.layers
      .whereType<OpacityLayer>()
      .where((layer) => (layer.alpha ?? 255) < 255);

  void close(WidgetTester tester) =>
      tester.state<NavigatorState>(find.byType(Navigator)).pop();

  testWidgets('while "Se redă acum" grows or shrinks, its content fades as '
      'an image of it, drawn once; open, the content is live',
      (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.text('open'));
    await tester.pump();

    // Opening takes 380 ms; the content shows from about a quarter in, and
    // is about half faded in at 160 ms.
    var paints = await pumpFrames(tester, 16);
    expect(fadingLayers(tester), isEmpty,
        reason: 'the image fades, not a layer of the live content');
    paints += await pumpFrames(tester, 20);
    expect(paints, 1, reason: 'drawn once, into the image that fades in');

    await tester.pumpAndSettle();
    expect(await pumpFrames(tester, 3), 3, reason: 'open, it is live');

    close(tester);
    await tester.pump();
    // Closing takes 300 ms; the content is about half faded out at 100 ms,
    // and gone by about two thirds in.
    paints = await pumpFrames(tester, 10);
    expect(fadingLayers(tester), isEmpty);
    paints += await pumpFrames(tester, 8);
    expect(paints, 0,
        reason: 'the image taken as it starts to close fades out');
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
          (widget) => widget is CustomPaint && widget.painter == painter),
      findsNothing,
      reason: 'closed',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a video (a texture) goes into the image with the rest',
      (tester) async {
    await pumpScreen(tester, content: const Texture(textureId: 1));
    await tester.tap(find.text('open'));
    await tester.pump();
    final paints = await pumpFrames(tester, 16);
    expect(fadingLayers(tester), isEmpty);
    expect(paints + await pumpFrames(tester, 20), 1);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a platform view, which no image can hold, fades live '
      'instead of throwing', (tester) async {
    await pumpScreen(tester, content: const _FakePlatformView());
    await tester.tap(find.text('open'));
    await tester.pump();
    final paints = await pumpFrames(tester, 16);
    expect(tester.takeException(), isNull);
    expect(fadingLayers(tester), hasLength(1), reason: 'it still fades');
    expect(paints + await pumpFrames(tester, 20), greaterThan(1),
        reason: 'live, every frame it shows');
    await tester.pumpAndSettle();
    expect(fadingLayers(tester), isEmpty);

    close(tester);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
