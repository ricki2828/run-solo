import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import '../tool/companion_facts_lib.dart';
import 'helpers.dart';

/// The converter must produce what `companionSummary` (lib/state/companion.dart)
/// would have uploaded: same keys, same rounding, nothing invented.
void main() {
  const allowed = {
    'run_id', 'type', 'start_utc', 'utc_offset_min', 'zone_id', 'duration_s',
    'distance_m', 'pace_s_per_km', 'true_pace_s_per_km', 'verdict', 'zone_min',
    'climb_m', 'locality', 'feel', 'route', 'splits', 'reps', //
  };
  final fourByFour = fixture('four_by_four_manual_clean_hr').run;
  final lapsRun = fixture('laps_run_manual_clean_hr').run;

  test(
    'payload keys are a subset of what the app sends, required ones present',
    () {
      final out = companionFactsFor([
        RunBundle(
          run: lapsRun,
          sidecar: RunSidecar(
            runId: lapsRun.id,
            zoneId: 'Asia/Singapore',
            utcOffsetMin: 480,
          ),
        ),
      ]);
      final p = out.single!;
      expect(allowed.containsAll(p.keys), isTrue, reason: '${p.keys}');
      for (final k in [
        'run_id',
        'type',
        'start_utc',
        'utc_offset_min',
        'zone_id',
        'duration_s',
        'distance_m',
      ]) {
        expect(p, contains(k));
      }
      expect(p['run_id'], lapsRun.id);
      expect(p['type'], 'laps');
      expect(p['zone_id'], 'Asia/Singapore');
      expect(p['utc_offset_min'], 480);
      expect(p['start_utc'], endsWith('Z'));
      expect(
        p.containsKey('verdict'),
        isFalse,
        reason: 'only an Intervals run carries a verdict',
      );
      final d = p['distance_m']! as double;
      expect((d * 10).round() / 10, d, reason: 'one decimal, like r1');
      expect(
        p['duration_s'],
        lapsRun.end.difference(lapsRun.start).inMilliseconds ~/ 1000 +
            ((lapsRun.end.difference(lapsRun.start).inMilliseconds % 1000) >=
                    500
                ? 1
                : 0),
      );
    },
  );

  test('an Intervals run carries the verdict word and zone minutes', () {
    final p = companionFactsFor([
      RunBundle(
        run: fourByFour,
        sidecar: RunSidecar(
          runId: fourByFour.id,
          zoneId: 'Europe/Athens',
          utcOffsetMin: 180,
        ),
      ),
    ], options: const CompanionFactsOptions(maxHr: 190)).single!;
    expect(p['type'], 'intervals');
    expect(VerdictHeadline.values.map((v) => v.name), contains(p['verdict']));
    final z = p['zone_min']! as Map<String, double>;
    expect(z.keys, ['z1', 'z2', 'z3', 'z4', 'z5']);
  });

  test(
    'route shape, splits and rep times ride along, inside the server bounds',
    () {
      RunBundle b(RunFile r) => RunBundle(
        run: r,
        sidecar: RunSidecar(
          runId: r.id,
          zoneId: 'Asia/Singapore',
          utcOffsetMin: 480,
        ),
      );
      final p = companionFactsFor([
        b(fourByFour),
      ], options: const CompanionFactsOptions(maxHr: 190)).single!;
      final reps = (p['reps']! as List).cast<Map<String, Object?>>();
      expect(reps, isNotEmpty);
      expect(reps.length, lessThanOrEqualTo(kMaxReps));
      for (final r in reps) {
        expect(r['time_s'], inInclusiveRange(1, 3600));
        expect(r['zone'], anyOf(isNull, inInclusiveRange(1, 5)));
      }
      final splits = (p['splits']! as List).cast<Map<String, Object?>>();
      var km = 0.0, secs = 0.0;
      for (final s in splits) {
        expect(s['km'] as double, inInclusiveRange(0.001, 1.0));
        expect(s['pace_s'] as double, inInclusiveRange(60, 3600));
        km += s['km']! as double;
        secs += (s['km']! as double) * (s['pace_s']! as double);
      }
      expect(km, closeTo((p['distance_m']! as double) / 1000, 0.05));
      expect(
        secs,
        closeTo(p['duration_s']! as int, 0.015 * (p['duration_s']! as int)),
      );
      final route = p['route'] as List?;
      if (route != null) {
        expect(route.length, inInclusiveRange(2, kRouteMaxPoints));
      }
      final off = companionFactsFor(
        [b(fourByFour)],
        options: const CompanionFactsOptions(maxHr: 190, withRoute: false),
      ).single!;
      expect(off.containsKey('route'), isFalse);
      expect(off['splits'], p['splits']);
    },
  );

  test('a second replay reuses the same secret zones (no new circle for the same door)', () {
    RunBundle b(RunFile r) => RunBundle(
      run: r,
      sidecar: RunSidecar(
        runId: r.id,
        zoneId: 'Asia/Singapore',
        utcOffsetMin: 480,
      ),
    );
    var kept = <PrivacyZone>[];
    companionFactsFor([
      b(fourByFour),
      b(lapsRun),
    ], options: CompanionFactsOptions(maxHr: 190, onZones: (z) => kept = z));
    final first = [...kept];
    var again = <PrivacyZone>[];
    companionFactsFor(
      [b(fourByFour), b(lapsRun)],
      options: CompanionFactsOptions(
        maxHr: 190,
        privacyZones: first,
        onZones: (z) => again = z,
      ),
    );
    expect(again.map((z) => z.toJson()), first.map((z) => z.toJson()));
  });

  test(
    'sorted oldest first, and later runs are compared with earlier ones',
    () {
      final a = lapsRun;
      final b = fourByFour;
      final out = companionFactsFor([RunBundle(run: b), RunBundle(run: a)]);
      final starts = [
        for (final p in out) DateTime.parse(p!['start_utc']! as String),
      ];
      expect(starts[0].isAfter(starts[1]), isFalse);
    },
  );

  test('zone id from a whole-hour offset, like the app', () {
    expect(zoneIdFor(null, 480), 'Etc/GMT-8');
    expect(zoneIdFor(null, -300), 'Etc/GMT+5');
    expect(zoneIdFor(null, 330), isNull);
    expect(zoneIdFor('Asia/Singapore', null), 'Asia/Singapore');
  });
}
