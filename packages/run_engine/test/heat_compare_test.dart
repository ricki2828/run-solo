import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Phase 3 W2 (plan §7, v1 plan §18.5): "Compare heat-adjusted paces".
/// Off, every verdict is the raw one, byte for byte. On, a run with usable
/// weather compares its adjusted headline with the adjusted twins of the
/// priors that have weather; a run without keeps its raw verdict and says
/// so. Flipping is like an engine bump: recomputed, history kept, and
/// flipping back restores the original verdicts.
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

  /// (pace s/km, weather) per run, one day apart, all 4x4s.
  RunFile run(int n, double pace) => runWithPaces(
    [pace, pace, pace, pace],
    id: '00000000-0000-4000-8000-0000000000${n.toString().padLeft(2, '0')}',
    start: day0.add(Duration(days: n)),
  );

  // Three cool runs at 300 with weather, one 280 with none (it would drag
  // the median), then the newest: 315 at 34 °C / dew 27 (≈ 8.8% slowdown,
  // ≈ 287 adjusted). Raw it is slower than usual; adjusted, quicker.
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
    required bool heat,
  }) {
    final priors = <PriorRun>[];
    final out = <RunAnalysis>[];
    for (final r in runs) {
      final a = engine.analyze(
        r,
        sidecar: sidecars[r.id],
        priors: List.of(priors),
        now: fixedNow,
        compareHeatAdjusted: heat,
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

  test('off: no heat fields in the verdict JSON, raw paces compared', () {
    final a = pass(fresh(), heat: false).last;
    final json = a.verdict!.toJson();
    expect(json.containsKey('heat_compare'), isFalse);
    expect(json.containsKey('heat_note'), isFalse);
    expect(a.verdict!.currentSecPerKm, closeTo(315, 0.5));
    expect(a.verdict!.setIds, contains(runs[2].id));
  });

  test('on: the adjusted headline against adjusted priors with weather', () {
    final off = pass(fresh(), heat: false).last.verdict!;
    final on = pass(fresh(), heat: true).last;
    final v = on.verdict!;
    final f = on.heat!.fraction!;
    expect(f, greaterThan(0.08));
    expect(
      v.currentSecPerKm,
      closeTo(on.intervals!.avgWorkPaceSecPerKm! * (1 - f), 1e-9),
    );
    // The no-weather run is not a prior of an adjusted comparison.
    expect(v.setIds, isNot(contains(runs[2].id)));
    expect(v.setIds, containsAll([runs[0].id, runs[1].id, runs[3].id]));
    expect(v.heatCompare, isTrue);
    // Four earlier runs, three with weather.
    expect(
      v.heatNote,
      'Heat-adjusted, compared with 3 of your 4 runs that have weather.',
    );
    expect(off.deltaSecPerKm, lessThan(0)); // raw: slower
    expect(v.deltaSecPerKm, greaterThan(0)); // adjusted: quicker
    expect(v.sameText(off), isFalse);
    // The detail figures stay raw.
    expect(on.intervals!.avgWorkPaceSecPerKm, closeTo(315, 0.5));
  });

  test('on, a run without weather: its raw verdict, and says so', () {
    final off = pass(fresh(), heat: false)[2].verdict!;
    final on = pass(fresh(), heat: true)[2].verdict!;
    expect(
      text(on)
        ..remove('heat_compare')
        ..remove('heat_note'),
      text(off),
    );
    expect(on.heatNote, heatMissingNote);
  });

  test('on, too hot to compare: raw verdict, its own note', () {
    final s = fresh();
    s[runs.last.id] = RunSidecar(runId: runs.last.id, weather: weather(38, 28));
    final v = pass(s, heat: true).last.verdict!;
    expect(v.heatNote, heatTooHotNote);
    expect(v.currentSecPerKm, closeTo(315, 0.5));
    // Raw against raw priors: the no-weather run counts again.
    expect(v.setIds, contains(runs[2].id));
  });

  test('flipping twice restores the original verdicts; history kept', () {
    final s = fresh();
    final original = [for (final a in pass(s, heat: false)) text(a.verdict!)];
    final on = pass(s, heat: true);
    expect(on.every((a) => a.verdictSource == VerdictSource.computed), isTrue);
    // The newest run's text changed, so the raw one moved to history.
    expect(s[runs.last.id]!.verdictHistory, hasLength(1));
    final back = pass(s, heat: false);
    expect([for (final a in back) text(a.verdict!)], original);
    expect(s[runs.last.id]!.verdictHistory, hasLength(2));
    // Runs whose text never changed gained no history line.
    expect(s[runs.first.id]!.verdictHistory, isEmpty);
    // No flip: restored as frozen.
    expect(
      pass(
        s,
        heat: false,
      ).every((a) => a.verdictSource == VerdictSource.frozen),
      isTrue,
    );
  });

  test('on, weather arriving later: gains the line, verdict not re-staged', () {
    final s = fresh();
    s[runs.last.id] = RunSidecar(runId: runs.last.id, weather: pending);
    final before = pass(s, heat: true).last;
    expect(before.verdict!.heatNote, heatMissingNote);
    s[runs.last.id] = s[runs.last.id]!.copyWith(weather: weather(34, 27));
    final after = pass(s, heat: true).last;
    expect(after.verdictSource, VerdictSource.frozen);
    expect(text(after.verdict!), text(before.verdict!));
    expect(after.heatLine, startsWith('Heat-adjusted estimate: '));
  });

  test('mixed keys: another key\'s priors never join, adjusted or not', () {
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
        compareHeatAdjusted: true,
      );
      expect(a.verdict!.setIds, isNot(contains('tempo-1')));
      final p = a.asPrior(r.start);
      if (p != null) priors.add(p);
    }
  });

  test('the note counts the earlier runs compared (#74 review P3)', () {
    expect(
      heatComparedNote(4, 9),
      'Heat-adjusted, compared with 4 of your 9 runs that have weather.',
    );
    expect(
      heatComparedNote(3, 3),
      'Heat-adjusted, compared with your 3 earlier runs.',
    );
    expect(
      heatComparedNote(1, 1),
      'Heat-adjusted, compared with your 1 earlier run.',
    );
    expect(
      heatComparedNote(0, 2),
      'Heat-adjusted, but none of your earlier runs have weather yet.',
    );
    expect(
      heatComparedNote(0, 0),
      'Heat-adjusted. No earlier runs to compare yet.',
    );
    // The first run under the setting, with weather: no earlier runs.
    expect(
      pass(fresh(), heat: true).first.verdict!.heatNote,
      heatComparedNote(0, 0),
    );
    for (final n in [heatComparedNote(4, 9), heatComparedNote(0, 2)]) {
      expect(n.contains('\u2014'), isFalse, reason: 'no em dashes');
    }
  });

  test('a prior carries its heat fraction through the index JSON', () {
    final a = pass(fresh(), heat: false);
    final hot = a.last.asPrior(runs.last.start)!;
    expect(hot.heatFraction, a.last.heat!.fraction);
    expect(PriorRun.fromJson(hot.toJson()).heatFraction, hot.heatFraction);
    final none = a[2].asPrior(runs[2].start)!;
    expect(none.toJson().containsKey('heat_adj'), isFalse);
  });
}
