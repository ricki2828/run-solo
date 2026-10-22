import 'dart:convert';
import 'dart:io';

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

/// The pre-run choice: its names, the month base for "furthest run this
/// month", and the `coach` log in the run file. Clocks are always pinned.
void main() {
  group('CoachChoice', () {
    test('names are stable and an unknown one is no choice', () {
      expect(CoachChoice.chase.key, 'chase');
      expect(CoachChoice.steady.key, 'steady');
      expect(CoachChoice.parse('chase'), CoachChoice.chase);
      expect(CoachChoice.parse('steady'), CoachChoice.steady);
      expect(CoachChoice.parse('sprint'), isNull);
      expect(CoachChoice.parse(null), isNull);
    });
  });

  group('MonthFurthest', () {
    // Wed 21 Oct 2026, 06:30 in Singapore (UTC+8): 22:30 UTC the day before.
    final now = DateTime(2026, 10, 21, 6, 30);

    BoardInput run(
      String id,
      DateTime date,
      double metres, {
      RunMode mode = RunMode.free,
      int? utcOffsetMin,
    }) => BoardInput(
      runId: id,
      date: date,
      utcOffsetMin: utcOffsetMin,
      mode: mode,
      runDistanceM: metres,
    );

    test('the longest run of this calendar month', () {
      final runs = [
        run('a', DateTime.utc(2026, 10, 3, 22), 5200, utcOffsetMin: 480),
        run('b', DateTime.utc(2026, 10, 12, 22), 8400, utcOffsetMin: 480),
        run('c', DateTime.utc(2026, 10, 15, 22), 6100, utcOffsetMin: 480),
      ];
      expect(MonthFurthest.of(runs, now: now), 8400);
    });

    test('last month does not count - not even a 21 km long run', () {
      final runs = [
        run('long', DateTime.utc(2026, 9, 27, 22), 21100, utcOffsetMin: 480),
        run('short', DateTime.utc(2026, 10, 2, 22), 3000, utcOffsetMin: 480),
      ];
      expect(MonthFurthest.of(runs, now: now), 3000);
    });

    test('a run keeps its own wall-clock month at the boundary', () {
      // 31 Oct 17:30 UTC is 1 Nov 01:30 in Singapore: a November run.
      final lateOct = run(
        'edge',
        DateTime.utc(2026, 10, 31, 17, 30),
        12000,
        utcOffsetMin: 480,
      );
      expect(MonthFurthest.of([lateOct], now: now), isNull);
      expect(MonthFurthest.of([lateOct], now: DateTime(2026, 11, 2, 7)), 12000);
      // The same instant with Sydney's offset (UTC+11) is also 1 Nov; with
      // New York's (UTC-4) it is still 31 Oct.
      final ny = run(
        'ny',
        DateTime.utc(2026, 10, 31, 17, 30),
        12000,
        utcOffsetMin: -240,
      );
      expect(MonthFurthest.of([ny], now: DateTime(2026, 10, 31, 23)), 12000);
    });

    test('no run this month, or only a short one, is no base', () {
      expect(MonthFurthest.of(const [], now: now), isNull);
      expect(
        MonthFurthest.of([
          run('short', DateTime.utc(2026, 10, 2, 22), 1900, utcOffsetMin: 480),
        ], now: now),
        isNull,
      );
      expect(
        MonthFurthest.of([
          run('exact', DateTime.utc(2026, 10, 2, 22), 2000, utcOffsetMin: 480),
        ], now: now),
        2000,
      );
    });

    test('Cooper tests, empty and broken distances are not runs', () {
      final runs = [
        run(
          'cooper',
          DateTime.utc(2026, 10, 5, 22),
          3100,
          mode: RunMode.cooper,
          utcOffsetMin: 480,
        ),
        run(
          'nan',
          DateTime.utc(2026, 10, 6, 22),
          double.nan,
          utcOffsetMin: 480,
        ),
        run('zero', DateTime.utc(2026, 10, 7, 22), 0, utcOffsetMin: 480),
        run('ok', DateTime.utc(2026, 10, 8, 22), 4300, utcOffsetMin: 480),
      ];
      expect(MonthFurthest.of(runs, now: now), 4300);
    });

    test('a run dated after now (a bad clock) is ignored', () {
      final runs = [
        run('future', DateTime.utc(2026, 10, 25, 22), 30000, utcOffsetMin: 480),
        run('real', DateTime.utc(2026, 10, 8, 22), 4300, utcOffsetMin: 480),
      ];
      expect(MonthFurthest.of(runs, now: now), 4300);
    });
  });

  group('run file coach log', () {
    final text = File('test/fixtures/contract/free_run_no_laps.json')
        .readAsStringSync();
    final run = RunFileCodec.decode(text);

    test('a run with no choice writes no key', () {
      expect(run.coach, isNull);
      expect(jsonDecode(RunFileCodec.encode(run)), isNot(contains('coach')));
    });

    test('the choice and its cues survive an encode and decode', () {
      final logged = run.copyWith(
        coach: const CoachLog(
          choice: 'chase',
          cues: [
            CoachCue('ahead', 2, 570000),
            CoachCue('furthest', 9, 3010000),
          ],
        ),
      );
      final back = RunFileCodec.decode(RunFileCodec.encode(logged));
      expect(back.coach, logged.coach);
      expect(back.coach!.cues.last.kind, 'furthest');
      expect(RunFileCodec.encode(back), RunFileCodec.encode(logged));
      expect(logged.copyWith(mode: RunMode.trail).coach, isNotNull);
      expect(logged.copyWith(coach: null).coach, isNull);
    });

    test('the Kotlin writer shape: coach {choice, cues [[kind, km, t]]}', () {
      final json = jsonDecode(text) as Map<String, Object?>;
      json['coach'] = {
        'choice': 'steady',
        'cues': [
          ['last2k', 3, 850000],
        ],
      };
      final read = RunFileCodec.decode(jsonEncode(json));
      expect(read.coach!.choice, 'steady');
      expect(read.coach!.cues.single, const CoachCue('last2k', 3, 850000));
    });

    test('a bad coach block is refused, a newer one is a newer file', () {
      Object? decode(Object? coach) {
        final json = jsonDecode(text) as Map<String, Object?>;
        json['coach'] = coach;
        return RunFileCodec.decode(jsonEncode(json));
      }

      expect(
        () => decode({
          'choice': 'chase',
          'cues': [1],
        }),
        throwsA(isA<RunFileFormatException>()),
      );
      expect(
        () => decode({'choice': '', 'cues': []}),
        throwsA(isA<RunFileFormatException>()),
      );
      expect(
        () => decode({'choice': 'chase', 'cues': [], 'answers': []}),
        throwsA(isA<RunFileNewerVersionException>()),
      );
    });
  });
}
