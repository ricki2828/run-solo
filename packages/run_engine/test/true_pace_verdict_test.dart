import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// True Pace in verdicts (v5): every pace a verdict compares has its hills
/// and heat taken out, priors included, always on. A flat, cool run (or one
/// with no weather or elevation) compares on its actual pace exactly as
/// before. Recalculated verdicts keep the old text as history.
void main() {
  final day0 = DateTime.utc(2026, 7, 1, 6);

  Map<String, Object?> weather(double temp, double dew) => WeatherRecord(
    status: WeatherStatus.ok,
    fetchedAt: fixedNow,
    latR: -33.9,
    lonR: 151.2,
    tempC: temp,
    rh: 65,
    dewPointC: dew,
    adj: HeatModel.of(tempC: temp, dewPointC: dew).fraction,
  ).toJson();
  final pending = const WeatherRecord(status: WeatherStatus.pending).toJson();

  RunFile run(int n, double pace, {double? grade}) {
    final r = runWithPaces(
      [pace, pace, pace, pace],
      id: '00000000-0000-4000-8000-0000000000${n.toString().padLeft(2, '0')}',
      start: day0.add(Duration(days: n)),
    );
    if (grade == null) return r;
    // A steady climb the whole way: elevation follows distance.
    return r.copyWith(
      elevSrc: ElevSource.baro,
      samples: [for (final s in r.samples) s.copyWith(elevM: s.distM * grade)],
    );
  }

  // Three cool runs at 300 with weather, one 280 with none (it counts now,
  // at its own neutral true pace), then the newest: 315 at 34 C / dew 27
  // (about 8.6% slowdown, about 288 true). Actual it is slower than usual;
  // true, quicker.
  final plan = <(double, Map<String, Object?>?)>[
    (300, weather(12, 5)),
    (300, weather(12, 5)),
    (280, null),
    (300, weather(12, 5)),
    (315, weather(34, 27)),
  ];
  final runs = [for (var i = 0; i < plan.length; i++) run(i + 1, plan[i].$1)];

  /// Analyses every run oldest first, freezing each computed verdict into
  /// [sidecars] as the store does.
  List<RunAnalysis> pass(
    Map<String, RunSidecar> sidecars, {
    List<RunFile>? files,
  }) {
    final priors = <PriorRun>[];
    final out = <RunAnalysis>[];
    for (final r in files ?? runs) {
      final a = engine.analyze(
        r,
        sidecar: sidecars[r.id],
        priors: List.of(priors),
        now: fixedNow,
      );
      sidecars[r.id] = a.freezeInto(sidecars[r.id]!);
      final p = a.asPrior(r.start);
      if (p != null) priors.add(p);
      out.add(a);
    }
    return out;
  }

  Map<String, RunSidecar> fresh() => {
    for (var i = 0; i < runs.length; i++)
      runs[i].id: RunSidecar(runId: runs[i].id, weather: plan[i].$2),
  };

  Map<String, Object?> text(Verdict v) => v.toJson()..remove('computed_at');

  test('a hot run compares its true pace against every prior', () {
    final on = pass(fresh()).last;
    final v = on.verdict!;
    final f = on.heat!.fraction!;
    expect(f, greaterThan(0.08));
    expect(
      v.currentSecPerKm,
      closeTo(on.intervals!.avgWorkPaceSecPerKm! * (1 - f), 1e-9),
    );
    // The run without weather is a prior now, at its own (neutral) pace.
    expect(v.setIds, contains(runs[2].id));
    expect(v.setIds, containsAll([runs[0].id, runs[1].id, runs[3].id]));
    // Slower than the median by the clock, quicker once the heat is out.
    expect(on.intervals!.avgWorkPaceSecPerKm, closeTo(315, 0.5));
    expect(v.deltaSecPerKm, greaterThan(0));
    expect(v.headline, VerdictHeadline.faster);
    // The actual pace travels with the verdict, and reads beside it.
    expect(v.rawSecPerKm, closeTo(315, 0.5));
    expect(v.heatFactor, closeTo(1 - f, 1e-9));
    expect(v.gradeFactor, 1);
    expect(v.truePaceLine(Units.km), '4:48 true pace (5:15 actual, hot day)');
  });

  test('a flat, cool run: byte for byte the actual-pace verdict', () {
    final cool = pass(fresh())[0].verdict!.toJson();
    expect(cool.containsKey('raw_s_per_km'), isFalse);
    expect(cool.containsKey('grade_x'), isFalse);
    expect(cool.containsKey('heat_x'), isFalse);
    // Not even a heat factor of 1 is written; none of it reads back as set.
    final back = Verdict.fromJson(cool);
    expect(back.gradeFactor, 1);
    expect(back.heatFactor, 1);
    expect(back.truePaceLine(Units.km), isNull);
    // A run with no weather at all: the same.
    final none = pass(fresh())[2];
    expect(none.verdict!.toJson().containsKey('heat_x'), isFalse);
    expect(none.workFactors.neutral, isTrue);
    expect(none.trueWorkPaceSecPerKm, none.intervals!.avgWorkPaceSecPerKm);
  });

  test('too hot to adjust: the heat stays in, and it says so', () {
    final s = fresh();
    s[runs.last.id] = RunSidecar(runId: runs.last.id, weather: weather(38, 28));
    final a = pass(s).last;
    expect(a.verdict!.currentSecPerKm, closeTo(315, 0.5));
    expect(a.verdict!.truePaceLine(Units.km), isNull);
    expect(a.heatLine, startsWith('Too hot to adjust (38 °C, dew point 28)'));
  });

  test('a hilly run: the hills come out of the work pace', () {
    final hills = <RunFile>[
      for (var i = 0; i < 4; i++) run(i + 1, 300),
      run(5, 315, grade: 0.03),
    ];
    final s = {for (final r in hills) r.id: RunSidecar(runId: r.id)};
    final a = pass(s, files: hills).last;
    expect(a.workFactors.grade, closeTo(1 / Gap.ratio(0.03), 0.02));
    expect(a.workFactors.grade, lessThan(0.9));
    final v = a.verdict!;
    expect(v.currentSecPerKm, lessThan(280));
    expect(v.headline, VerdictHeadline.faster);
    expect(v.rawSecPerKm, closeTo(315, 0.5));
    expect(v.truePaceLine(Units.km), contains('actual, hilly)'));
    // The grade factor rides on the prior it becomes.
    final prior = a.asPrior(hills.last.start)!;
    expect(prior.gradeFactor, a.workFactors.grade);
    expect(
      prior.truePace().avgWorkPaceSecPerKm,
      closeTo(v.currentSecPerKm!, 1e-9),
    );
    expect(PriorRun.fromJson(prior.toJson()).gradeFactor, prior.gradeFactor);
  });

  test(
    'verdicts recalculate on an engine update, old text kept as history',
    () {
      final s = fresh();
      final first = pass(s);
      final last = runs.last;
      // What v4 froze for the hot run: the actual-pace verdict, SLOWER.
      final old = Verdict.fromJson(
        first.last.verdict!.toJson()
          ..['engine_version'] = engineVersion - 1
          ..['headline_key'] = 'slower'
          ..['headline'] = 'SLOWER'
          ..['subline'] = 'Old words from the actual-pace engine.'
          ..remove('raw_s_per_km')
          ..remove('heat_x'),
      );
      s[last.id] = RunSidecar(
        runId: last.id,
        weather: plan.last.$2,
        frozenVerdict: old,
      );
      final again = pass(s).last;
      expect(again.verdictSource, VerdictSource.computed);
      expect(again.verdict!.headline, VerdictHeadline.faster);
      expect(s[last.id]!.frozenVerdict!.headline, VerdictHeadline.faster);
      expect(s[last.id]!.verdictHistory, hasLength(1));
      expect(
        s[last.id]!.verdictHistory.single.subline,
        'Old words from the actual-pace engine.',
      );
      // A run whose text did not change gains no history line.
      expect(s[runs.first.id]!.verdictHistory, isEmpty);
    },
  );

  test('weather arriving later: the verdict is not re-staged', () {
    final s = fresh();
    s[runs.last.id] = RunSidecar(runId: runs.last.id, weather: pending);
    final before = pass(s).last;
    expect(before.verdict!.heatFactor, 1);
    s[runs.last.id] = s[runs.last.id]!.copyWith(weather: weather(34, 27));
    final after = pass(s).last;
    expect(after.verdictSource, VerdictSource.frozen);
    expect(text(after.verdict!), text(before.verdict!));
  });

  test('another key\'s priors never join', () {
    final other = PriorRun(
      id: 'tempo-1',
      start: day0,
      avgWorkPaceSecPerKm: 250,
      comparisonKey: 't1200x*',
      heatFraction: 0,
    );
    final s = fresh();
    final priors = <PriorRun>[other];
    for (final r in runs) {
      final a = engine.analyze(
        r,
        sidecar: s[r.id],
        priors: List.of(priors),
        now: fixedNow,
      );
      expect(a.verdict!.setIds, isNot(contains('tempo-1')));
      final p = a.asPrior(r.start);
      if (p != null) priors.add(p);
    }
  });

  test('a prior carries its heat and hills through the index JSON', () {
    final a = pass(fresh());
    final hot = a.last.asPrior(runs.last.start)!;
    expect(hot.heatFraction, a.last.heat!.fraction);
    expect(PriorRun.fromJson(hot.toJson()).heatFraction, hot.heatFraction);
    final none = a[2].asPrior(runs[2].start)!;
    expect(none.toJson().containsKey('heat_adj'), isFalse);
    expect(none.toJson().containsKey('grade_x'), isFalse);
  });
}
