import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/load_guard.dart';
import 'package:run_solo/state/run_index.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/state/zone_histogram.dart';

import '../run_fixtures.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('load-'));
  tearDown(() => dir.delete(recursive: true));

  group('average heart rate from a run file', () {
    test('mean over moving time with a reading, plus coverage', () {
      final run = freeRunFile(n: 1, start: DateTime.utc(2026, 9, 10, 6));
      final s = hrSummaryOf(run)!;
      expect(s.avgHr, inInclusiveRange(60, 220));
      expect(s.coverage, closeTo(1, 0.01));
    });

    test('no strap means no summary, never a zero', () {
      final run = freeRunFile(
        n: 2,
        start: DateTime.utc(2026, 9, 10, 6),
        hr: false,
      );
      expect(hrSummaryOf(run), isNull);
    });

    test('a strap that dropped halfway reports half coverage', () {
      final run = freeRunFile(n: 3, start: DateTime.utc(2026, 9, 10, 6));
      final half = run.samples.length ~/ 2;
      final patched = run.copyWith(
        samples: [
          for (var i = 0; i < run.samples.length; i++)
            i >= half ? run.samples[i].copyWith(hr: null) : run.samples[i],
        ],
      );
      expect(hrSummaryOf(patched)!.coverage, closeTo(0.5, 0.02));
    });
  });

  group('index row', () {
    test(
      'keeps avg HR and coverage through JSON, and drops them when absent',
      () {
        const row = IndexRow(lapCount: 0, avgHr: 151.2, hrCoverage: 0.97);
        final back = IndexRow.fromJson(row.toJson())!;
        expect(back.avgHr, 151.2);
        expect(back.hrCoverage, 0.97);
        final none = IndexRow.fromJson(const IndexRow(lapCount: 0).toJson())!;
        expect(none.avgHr, isNull);
        expect(none.toJson().containsKey('avg_hr'), isFalse);
      },
    );

    test(
      'a real run through FileRunStore carries it, History reads the row',
      () async {
        final store = FileRunStore(
          Directory('${dir.path}/runs'),
          profile: () => const engine.UserProfile(age: 40),
        );
        store.deriveBatch = FileRunStore.deriveInIsolate;
        final withHr = freeRunFile(n: 1, start: DateTime.utc(2026, 9, 10, 6));
        final noHr = freeRunFile(
          n: 2,
          start: DateTime.utc(2026, 9, 11, 6),
          hr: false,
        );
        await store.importBundles([
          engine.RunBundle(run: withHr),
          engine.RunBundle(run: noHr),
        ]);
        final rows = await store.list();
        await store.derivedIdle;
        expect(rows.every((r) => r.analysis == null), isTrue);
        final a = rows.firstWhere((r) => r.id == withHr.id).row!;
        final b = rows.firstWhere((r) => r.id == noHr.id).row!;
        expect(a.version, IndexRow.currentVersion);
        expect(a.avgHr, isNotNull);
        expect(b.avgHr, isNull);
        final runs = LoadInputs.runs(rows);
        expect(runs, hasLength(2));
        expect(
          runs.firstWhere((r) => r.avgHr != null).hrCoverage,
          closeTo(1, 0.01),
        );
        expect(runs.every((r) => r.movingMin > 0), isTrue);
        await store.derivedIdle;
      },
    );
  });

  group('dates', () {
    test('an SGT 6am run stored as UTC counts on its own day', () {
      final r = RunSummary(
        id: 'sgt',
        mode: RecordMode.free,
        start: DateTime.utc(2026, 10, 4, 22),
        durationMs: 2400000,
        distanceM: 6000,
        laps: 0,
        utcOffsetMin: 480,
        row: const IndexRow(lapCount: 0, movingMs: 2400000),
      );
      final s = LoadInputs.runs([r]).single.start;
      expect([s.day, s.hour], [5, 6]);
    });
  });

  group('dismissal', () {
    test('keyed on the Monday, written through settings', () {
      final now = DateTime(2026, 10, 14);
      const s = AppSettings();
      expect(LoadDismissal.dismissed(s, now), isFalse);
      final d = LoadDismissal.dismiss(now)(s);
      expect(d.loadDismissedWeek, '2026-10-12');
      expect(LoadDismissal.dismissed(d, now), isTrue);
      expect(LoadDismissal.dismissed(d, DateTime(2026, 10, 18)), isTrue);
      expect(LoadDismissal.dismissed(d, DateTime(2026, 10, 19)), isFalse);
      expect(AppSettings.fromJson(d.toJson()).loadDismissedWeek, '2026-10-12');
    });
  });
}
