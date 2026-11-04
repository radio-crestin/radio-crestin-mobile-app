import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/widgets/baked_decoration.dart';

void main() {
  const decoration = BoxDecoration(
    gradient: LinearGradient(colors: [Color(0xff4a1a2c), Color(0xff170b10)]),
  );

  RenderBakedDecoration renderOf(WidgetTester tester) =>
      tester.renderObject<RenderBakedDecoration>(find.byType(BakedDecoration));

  Future<void> pumpBox(WidgetTester tester) => tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: BakedDecoration(
            decoration: decoration,
            child: SizedBox.expand(),
          ),
        ),
      );

  tearDown(() {
    TestWidgetsFlutterBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  test('shades an image only in the foreground', () {
    expect(RenderBakedDecoration.canBakeIn(AppLifecycleState.resumed), isTrue);
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
      null,
    ]) {
      expect(RenderBakedDecoration.canBakeIn(state), isFalse,
          reason: '$state');
    }
  });

  testWidgets('in the foreground, the image is shaded and kept',
      (tester) async {
    await pumpBox(tester);

    expect(renderOf(tester).hasBakedImage, isTrue);
  });

  testWidgets(
      'out of the foreground a new look is painted directly, and shaded '
      'once the app is back', (tester) async {
    await pumpBox(tester);
    // Frames still run while inactive (paused stops them in tests).
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: BakedDecoration(
          decoration: BoxDecoration(color: Color(0xfffce4ec)),
          child: SizedBox.expand(),
        ),
      ),
    );
    expect(renderOf(tester).hasBakedImage, isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(renderOf(tester).hasBakedImage, isTrue);
  });

  testWidgets('coming back shades the image afresh', (tester) async {
    await pumpBox(tester);
    final render = renderOf(tester);
    expect(render.hasBakedImage, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(render.hasBakedImage, isFalse);
    expect(render.debugNeedsPaint, isTrue);

    await tester.pump();
    expect(render.hasBakedImage, isTrue);
  });
}
