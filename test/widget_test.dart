import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart';
import 'package:run_solo/main.dart';
import 'package:run_solo/theme/theme.dart';

void main() {
  testWidgets('home screen renders in Night Session theme', (tester) async {
    await tester.pumpWidget(const RunSoloApp());

    expect(find.text('RUN SOLO'), findsOneWidget);
    expect(find.text('START'), findsOneWidget);

    final context = tester.element(find.text('RUN SOLO'));
    final tokens = Theme.of(context).extension<RunSoloTokens>();
    expect(tokens, isNotNull);
    expect(tokens!.bgBase, NightSession.bgBase);
    expect(Theme.of(context).colorScheme.tertiary, NightSession.accentArc);
  });

  test('app depends on the pure-Dart engine', () {
    expect(engineVersion, greaterThanOrEqualTo(1));
  });
}
