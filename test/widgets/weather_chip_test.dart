import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_engine/testing.dart' as synth;
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/widgets/weather_chip.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

final DateTime d1 = DateTime.utc(2026, 9, 20, 6);
const runEngine = engine.RunEngine();

engine.WeatherRecord ok(double temp, double dew) => engine.WeatherRecord(
  status: engine.WeatherStatus.ok,
  fetchedAt: d1,
  latR: -33.9,
  lonR: 151.2,
  tempC: temp,
  rh: 62,
  dewPointC: dew,
  adj: engine.HeatModel.of(tempC: temp, dewPointC: dew).fraction,
);

engine.RunAnalysis analyse(engine.RunFile run, engine.WeatherRecord? w) =>
    runEngine.analyze(
      run,
      sidecar: engine.RunSidecar(runId: run.id, weather: w?.toJson()),
      now: d1.add(const Duration(days: 1)),
    );

engine.RunFile cooperFile() => generator
    .generate(
      synth.SyntheticSpec(
        name: 'fixture_cooper',
        id: runId(9),
        mode: engine.RunMode.cooper,
        lapStyle: synth.LapStyle.none,
        start: d1,
        segments: [synth.Segment.free(720, 4.0)],
      ),
    )
    .run;

WeatherChipView view(
  engine.RunFile run,
  engine.WeatherRecord? w, {
  bool enabled = true,
  Units units = Units.km,
}) => weatherChipView(
  analysis: analyse(run, w),
  units: units,
  fetchEnabled: enabled,
)!;

void main() {
  final run = fourByFourFile(n: 1, start: d1);

  test('no weather yet: fetching when the setting is on, nothing when off', () {
    expect(view(run, null).state, WeatherChipState.pending);
    expect(view(run, null).note, kWeatherPending);
    expect(
      weatherChipView(
        analysis: analyse(run, null),
        units: Units.km,
        fetchEnabled: false,
      ),
      isNull,
    );
    expect(
      view(
        run,
        const engine.WeatherRecord(status: engine.WeatherStatus.pending),
      ).state,
      WeatherChipState.pending,
    );
  });

  test('indoor or skipped: no chip, never "fetching"', () {
    final indoor = fourByFourFile(n: 2, start: d1, indoor: true);
    expect(
      weatherChipView(
        analysis: analyse(indoor, null),
        units: Units.km,
        fetchEnabled: true,
      ),
      isNull,
    );
    expect(
      weatherChipView(
        analysis: analyse(
          run,
          const engine.WeatherRecord(status: engine.WeatherStatus.skipped),
        ),
        units: Units.km,
        fetchEnabled: true,
      ),
      isNull,
    );
  });

  test('unavailable: said, raw only', () {
    final v = view(
      run,
      const engine.WeatherRecord(status: engine.WeatherStatus.failed),
    );
    expect(v.state, WeatherChipState.unavailable);
    expect(v.note, kWeatherUnavailable);
    expect(v.raw, isNotNull);
    expect(v.adjusted, isNull);
    expect(v.sheet, isEmpty);
  });

  test('cool: weather line, raw, "No heat adjustment"', () {
    final v = view(run, ok(12, 5));
    expect(v.state, WeatherChipState.cool);
    expect(v.conditions, '12 °C · 62% · dew point 5 °C');
    expect(v.note, kNoHeatAdjustment);
    expect(v.adjusted, isNull);
  });

  test('warm: raw first, adjusted twin = raw x (1 - adj), rough estimate', () {
    final a = analyse(run, ok(28, 21));
    final v = view(run, ok(28, 21));
    final f = engine.HeatModel.of(tempC: 28, dewPointC: 21).fraction!;
    final raw = a.intervals!.avgWorkPaceSecPerKm!;
    expect(v.state, WeatherChipState.adjusted);
    expect(v.rawLabel, 'RAW');
    expect(v.raw, '${engine.PaceFormat.paceBare(raw, engine.Units.km)} /km');
    expect(
      v.adjusted,
      '${engine.PaceFormat.paceBare(raw * (1 - f), engine.Units.km)} /km',
    );
    expect(
      v.note,
      '+${(f * 100).toStringAsFixed(1)}% for heat, a rough estimate',
    );
    // The verdict screen's line comes from the same model.
    expect(a.heatLine, startsWith('Heat-adjusted estimate: '));
  });

  test('miles: both paces per mile', () {
    final v = view(run, ok(28, 21), units: Units.mi);
    expect(v.raw, endsWith(' /mi'));
    expect(v.adjusted, endsWith(' /mi'));
  });

  test('too hot: said in warn, raw only, no adjusted number', () {
    final v = view(run, ok(38, 28));
    expect(v.state, WeatherChipState.tooHot);
    expect(v.note, kTooHotRawOnly);
    expect(v.adjusted, isNull);
  });

  test('a Cooper test uses its own WBGT model, not the Hadley table', () {
    final cooper = cooperFile();
    final w = ok(28, 21);
    final v = view(cooper, w);
    final c = engine.CooperHeat.of(w)!;
    final hadley = engine.HeatModel.of(tempC: 28, dewPointC: 21).fraction!;
    expect(c.fraction, isNot(closeTo(hadley, 1e-6)));
    expect(v.state, WeatherChipState.adjusted);
    expect(
      v.note,
      '+${(c.fraction! * 100).toStringAsFixed(1)}% for heat, a rough estimate',
    );
    expect(v.sheet, kCooperHeatSheet);
  });

  test('copy: every adjusted number says estimate; no em dashes', () {
    final views = [
      view(run, null),
      view(
        run,
        const engine.WeatherRecord(status: engine.WeatherStatus.failed),
      ),
      view(run, ok(12, 5)),
      view(run, ok(28, 21)),
      view(run, ok(38, 28)),
      view(cooperFile(), ok(28, 21)),
    ];
    for (final v in views) {
      if (v.adjusted != null) {
        expect(engine.carriesEstimateMarker(v.adjustedLabel!), isTrue);
        expect(engine.carriesEstimateMarker(v.note!), isTrue, reason: v.note);
      }
      for (final s in v.strings) {
        expect(s.contains('—'), isFalse, reason: s);
      }
    }
    expect(engine.carriesEstimateMarker(kSteadyHeatSheet.first), isTrue);
    expect(kSteadyHeatSheet.last, startsWith('Weather data by Open-Meteo.com'));
    expect(kCooperHeatSheet.last, startsWith('Weather data by Open-Meteo.com'));
  });

  testWidgets('ⓘ opens the sheet: table, steady-running caveat, attribution', (
    tester,
  ) async {
    await loadRunSoloFonts();
    await tester.pumpWidget(
      MaterialApp(
        theme: runSoloTheme(),
        home: Scaffold(body: WeatherChip(view: view(run, ok(28, 21)))),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('weather-info')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('weather-sheet')), findsOneWidget);
    expect(find.textContaining('Hadley'), findsOneWidget);
    expect(
      find.text(
        'Built for steady running. Short hard reps are probably less affected.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Open-Meteo.com'), findsOneWidget);
  });
}
