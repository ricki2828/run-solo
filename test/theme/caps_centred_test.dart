import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/theme/caps_text.dart';
import 'package:run_solo/theme/theme.dart';

import '../helpers.dart';

/// Vertical middle of the drawn caps of the [Text] under [button], in global
/// px, from the paragraph's own baseline (so the CapsText translate counts).
double capsMid(WidgetTester tester, Finder button) {
  final text = find.descendant(of: button, matching: find.byType(Text));
  final para = tester.renderObject<RenderParagraph>(
    find.descendant(of: text, matching: find.byType(RichText)).first,
  );
  final size = para.text.style!.fontSize!;
  final top = tester
      .getTopLeft(
        find.descendant(of: text, matching: find.byType(RichText)).first,
      )
      .dy;
  final baseline = para.computeDistanceToActualBaseline(
    TextBaseline.alphabetic,
  );
  return top + baseline - kSairaCapEm * size / 2;
}

Future<void> pumpButton(
  WidgetTester tester,
  Widget label,
  double height, {
  TextStyle? textStyle,
}) async {
  await loadRunSoloFonts();
  await tester.pumpWidget(
    MaterialApp(
      theme: runSoloTheme(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 320,
            child: FilledButton(
              key: const ValueKey('b'),
              onPressed: () {},
              style: FilledButton.styleFrom(
                minimumSize: Size.fromHeight(height),
                textStyle: textStyle,
              ),
              child: label,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  final cases = <String, (double, TextStyle?)>{
    'Ready START (display96, 104 high)': (104, RunSoloType.display96),
    'READY UP / Home CTA / Nice (theme title28, 64 high)': (64, null),
    'NUMBERS-size display44 28 (56 high)': (
      56,
      RunSoloType.display44.copyWith(fontSize: RunSoloType.runSize(28)),
    ),
  };
  for (final e in cases.entries) {
    testWidgets('CapsText centres ${e.key} within 2 px', (tester) async {
      await pumpButton(
        tester,
        const CapsText('START'),
        e.value.$1,
        textStyle: e.value.$2,
      );
      final b = tester.getRect(find.byKey(const ValueKey('b')));
      expect(
        (capsMid(tester, find.byKey(const ValueKey('b'))) - b.center.dy).abs(),
        lessThan(2),
      );
    });
  }

  testWidgets(
    'a plain Text in the same button is off-centre (guards the test)',
    (tester) async {
      await pumpButton(
        tester,
        const Text('START'),
        104,
        textStyle: RunSoloType.display96,
      );
      final b = tester.getRect(find.byKey(const ValueKey('b')));
      expect(
        (capsMid(tester, find.byKey(const ValueKey('b'))) - b.center.dy).abs(),
        greaterThan(2),
      );
    },
  );
}
