import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/home_progress.dart';
import 'package:run_solo/state/settings.dart';

import '../helpers.dart';

engine.IdentityScore score(
  engine.IdentityLane lane, {
  double vdot = 40,
  double? prior,
  int daysAgo = 3,
  String source = '4x4 work pace',
}) => engine.IdentityScore(
  lane: lane,
  score: 60,
  vdot: vdot,
  priorVdot: prior,
  priorSource: prior == null ? null : source,
  runId: lane.name,
  date: testNow.subtract(Duration(days: daysAgo)),
  source: source,
  boardKey: null,
);

Scores all({int daysAgo = 3, double? prior}) => {
  for (final l in engine.IdentityLane.values)
    l: score(l, daysAgo: daysAgo, prior: prior, source: '5K'),
};

ProgressHeadline headline(Scores s) =>
    ProgressHeadline.of(s, now: testNow, sex: ProfileSex.male, age: 44);

Recommendation rec(Scores s, [List<RunSummary> runs = const []]) =>
    Recommendation.of(s, runs, now: testNow, sex: ProfileSex.male, age: 44);

RunSummary run(String id, int daysAgo, {String? template, double m = 6000}) =>
    RunSummary(
      id: id,
      mode: template == null ? RecordMode.free : RecordMode.intervals,
      start: testNow.subtract(Duration(days: daysAgo)),
      durationMs: 1800000,
      distanceM: m,
      laps: 0,
      spec: template == null ? null : engine.SessionCatalogue.expand(template),
    );

/// A vdot whose percentile for [lane] lands in [lo]..[hi] for a 44-year-old
/// man, so the test does not hard-code the norm tables.
double vdotIn(engine.IdentityLane lane, int lo, int hi, String source) {
  for (var v = 20.0; v < 90; v += 0.5) {
    final p = ScoreNorms.percentile(
      lane,
      v,
      source,
      sex: ProfileSex.male,
      age: 44,
    );
    if (p != null && p >= lo && p <= hi) return v;
  }
  throw StateError('no vdot for $lo..$hi');
}

void main() {
  group('statement', () {
    test('50th percentile and up: N in 10, rounded down, capped at 9', () {
      for (final (lo, hi) in [(50, 59), (60, 69), (70, 79), (90, 99)]) {
        final v = vdotIn(engine.IdentityLane.aerobic, lo, hi, 'Cooper test');
        final st = ProgressStatement.of(
          score(engine.IdentityLane.aerobic, vdot: v, source: 'Cooper test'),
          sex: ProfileSex.male,
          age: 44,
        )!;
        final p = ScoreNorms.percentile(
          engine.IdentityLane.aerobic,
          v,
          'Cooper test',
          sex: ProfileSex.male,
          age: 44,
        )!;
        expect(st.big, '${(p ~/ 10).clamp(5, 9)} in 10');
        expect(st.tail, 'men your age are slower than you.');
        expect(st.tag, 'M40-49');
        expect(st.lane, engine.IdentityLane.aerobic);
      }
    });

    test('below the 50th: building, no ranking', () {
      final v = vdotIn(engine.IdentityLane.aerobic, 1, 49, 'Cooper test');
      final st = ProgressStatement.of(
        score(engine.IdentityLane.aerobic, vdot: v, source: 'Cooper test'),
        sex: ProfileSex.male,
        age: 44,
      )!;
      expect(st.big, 'AEROBIC');
      expect(st.tail, 'is building.');
      expect(st.tail, isNot(contains('slower')));
    });

    test('the words follow the direction: slipped, steady, building', () {
      final low = vdotIn(engine.IdentityLane.aerobic, 5, 25, 'Cooper test');
      final high = vdotIn(engine.IdentityLane.aerobic, 30, 49, 'Cooper test');
      String tail(double now, double prior) => ProgressStatement.of(
        score(
          engine.IdentityLane.aerobic,
          vdot: now,
          prior: prior,
          source: 'Cooper test',
        ),
        sex: ProfileSex.male,
        age: 44,
        change: ScoreNorms.change(
          score(
            engine.IdentityLane.aerobic,
            vdot: now,
            prior: prior,
            source: 'Cooper test',
          ),
          sex: ProfileSex.male,
          age: 44,
        ),
      )!.tail;
      expect(tail(low, high), 'slipped.');
      expect(tail(high, low), 'is building.');
      expect(tail(low, low), 'is holding steady.');
    });

    test('a headline that goes DOWN never says "is building"', () {
      final s = {
        engine.IdentityLane.aerobic: score(
          engine.IdentityLane.aerobic,
          vdot: vdotIn(engine.IdentityLane.aerobic, 5, 25, 'Cooper test'),
          prior: vdotIn(engine.IdentityLane.aerobic, 30, 49, 'Cooper test'),
          source: 'Cooper test',
        ),
      };
      final h = headline(s);
      expect(h.kind, ProgressKind.down);
      expect(h.title, startsWith('AEROBIC DOWN '));
      expect(h.statement!.tail, 'slipped.');
    });

    test('no profile, no statement', () {
      final h = ProgressHeadline.of(
        all(),
        now: testNow,
        sex: ProfileSex.notSet,
        age: null,
      );
      expect(h.statement, isNull);
    });

    test('keeps the sub-line and names the top mover', () {
      final s = {
        engine.IdentityLane.aerobic: score(
          engine.IdentityLane.aerobic,
          vdot: 52,
          prior: 44,
          source: 'Cooper test',
        ),
        engine.IdentityLane.mid: score(
          engine.IdentityLane.mid,
          vdot: 44,
          prior: 44,
          source: '5K',
        ),
      };
      final h = headline(s);
      expect(h.kind, ProgressKind.up);
      expect(h.title, startsWith('AEROBIC UP'));
      expect(h.statement!.lane, engine.IdentityLane.aerobic);
    });
  });

  group('ProgressMove', () {
    test('direction words follow the sign, biggest move first', () {
      final s = {
        engine.IdentityLane.aerobic: score(
          engine.IdentityLane.aerobic,
          vdot: vdotIn(engine.IdentityLane.aerobic, 5, 25, 'Cooper test'),
          prior: vdotIn(engine.IdentityLane.aerobic, 30, 49, 'Cooper test'),
          source: 'Cooper test',
        ),
        engine.IdentityLane.mid: score(
          engine.IdentityLane.mid,
          vdot: 46,
          prior: 45.5,
          source: '5K',
        ),
      };
      final moves = ProgressMove.of(s, sex: ProfileSex.male, age: 44);
      expect(moves.first.lane, engine.IdentityLane.aerobic);
      expect(moves.first.change, isNegative);
      expect(moves.first.words, startsWith('slipped '));
      for (final m in moves.skip(1)) {
        expect(
          m.words,
          m.change < 0 ? startsWith('slipped ') : startsWith('up '),
        );
      }
    });

    test('nothing moved, nothing to say', () {
      expect(ProgressMove.of(all(), sex: ProfileSex.male, age: 44), isEmpty);
      expect(ProgressMove.of(const {}, sex: ProfileSex.male, age: 44), isEmpty);
    });
  });

  group('headline', () {
    test('none: first runs set the scores', () {
      final h = headline(const {});
      expect(h.kind, ProgressKind.none);
      expect(h.title, 'SET YOUR SCORES');
    });

    test('scores with nothing to compare against yet', () {
      final h = headline(all());
      expect(h.kind, ProgressKind.baseline);
      expect(h.title, 'SCORES SET');
      // Profile is known: never ask for it.
      expect(h.line, 'Changes show once you have six weeks of runs.');
    });

    test('scores set but no profile: asks for it, nothing else', () {
      final h = ProgressHeadline.of(
        all(),
        now: testNow,
        sex: ProfileSex.notSet,
        age: null,
      );
      expect(h.kind, ProgressKind.baseline);
      expect(h.line, 'Add your sex and birth year in Settings to compare.');
    });

    test('12-minute test, not Cooper', () {
      final s = {
        engine.IdentityLane.aerobic: score(
          engine.IdentityLane.aerobic,
          vdot: 46,
          prior: 40,
          source: 'Cooper test',
        ),
      };
      expect(headline(s).line, contains('Your 12-minute test on '));
      expect(headline(s).line, isNot(contains('Cooper')));
    });

    test('trail run, from either lane, reads as "trail run"', () {
      for (final source in ['trail run', engine.TrailScore.longSource]) {
        final s = {
          engine.IdentityLane.aerobic: score(
            engine.IdentityLane.aerobic,
            vdot: 46,
            prior: 40,
            source: source,
          ),
        };
        expect(
          headline(s).line,
          contains('Your trail run on '),
          reason: source,
        );
        expect(headline(s).line, isNot(contains('effort pace')));
      }
    });

    test('steady: same reading as six weeks ago, period named', () {
      final h = headline(all(prior: 40));
      expect(h.kind, ProgressKind.steady);
      expect(h.title, 'HOLDING STEADY');
      expect(h.line, startsWith('Since '));
    });

    test('up: the biggest mover, with the run that did it', () {
      final s = {
        ...all(prior: 40),
        engine.IdentityLane.aerobic: score(
          engine.IdentityLane.aerobic,
          vdot: 46,
          prior: 40,
          daysAgo: 2,
          source: '4x4 work pace',
        ),
      };
      final h = headline(s);
      final delta = ScoreNorms.change(
        s[engine.IdentityLane.aerobic]!,
        sex: ProfileSex.male,
        age: 44,
      )!;
      expect(delta, greaterThan(0));
      expect(h.kind, ProgressKind.up);
      expect(h.title, 'AEROBIC UP $delta');
      expect(h.line, contains('Your 4x4 on '));
      expect(h.line, endsWith('did it.'));
    });

    test('down: said plainly, no shaming', () {
      final s = {
        ...all(prior: 40),
        engine.IdentityLane.speed: score(
          engine.IdentityLane.speed,
          vdot: 34,
          prior: 40,
          daysAgo: 20,
        ),
      };
      final h = headline(s);
      expect(h.kind, ProgressKind.down);
      expect(h.title, startsWith('SPEED DOWN '));
      expect(h.line, contains('Your earlier best has rolled off.'));
      expect(h.line, contains('Faster recent runs raise it.'));
      expect(h.line, isNot(contains('!')));
    });
  });

  group('recommendation', () {
    test('stalled lane: the one waiting longest, with its weeks', () {
      final s = {
        ...all(),
        engine.IdentityLane.speed: score(
          engine.IdentityLane.speed,
          daysAgo: 21,
        ),
      };
      final r = rec(s);
      expect(r.lane, engine.IdentityLane.speed);
      expect(r.reason, "SPEED hasn't moved in 3 weeks. Try 8 × 400 m.");
      expect(r.startLabel, '8 × 400 m ›');
    });

    test('missing lane comes first and says what unlocks it', () {
      final s = {...all()}..remove(engine.IdentityLane.long);
      final r = rec(s);
      expect(r.lane, engine.IdentityLane.long);
      expect(r.reason, 'LONG needs a 15K+ run to count.');
    });

    test('a missing MID says why the latest run did not count', () {
      final s = {...all()}..remove(engine.IdentityLane.mid);
      const why = "Your 5K on 20 Oct didn't count: paused at 3.2 km";
      final r = Recommendation.of(
        s,
        const [],
        now: testNow,
        sex: ProfileSex.male,
        age: 44,
        midNote: why,
      );
      expect(r.lane, engine.IdentityLane.mid);
      expect(r.reason, '$why. A clean 5K sets MID.');
      // Without a reason the generic hint stays.
      expect(rec(s).reason, 'MID needs a 5K or 10K run to count.');
    });

    test('a stalled MID keeps its reason; other lanes ignore it', () {
      final stalled = {
        ...all(),
        engine.IdentityLane.mid: score(engine.IdentityLane.mid, daysAgo: 30),
      };
      final r = Recommendation.of(
        stalled,
        const [],
        now: testNow,
        sex: ProfileSex.male,
        age: 44,
        midNote: 'Your 5K on 20 Oct didn\'t count: GPS dropped at 4.1 km',
      );
      expect(
        r.reason,
        "MID hasn't moved in 4 weeks. Your 5K on 20 Oct didn't count: GPS "
        'dropped at 4.1 km.',
      );
      final long = Recommendation.of(
        {...all()}..remove(engine.IdentityLane.long),
        const [],
        now: testNow,
        sex: ProfileSex.male,
        age: 44,
        midNote: 'ignored',
      );
      expect(long.reason, 'LONG needs a 15K+ run to count.');
    });

    test('nothing stalled or missing: keep the oldest climbing', () {
      final s = {
        ...all(),
        engine.IdentityLane.aerobic: score(
          engine.IdentityLane.aerobic,
          daysAgo: 8,
        ),
      };
      final r = rec(s);
      expect(r.reason, 'AEROBIC: a Norwegian 4x4 this week keeps it climbing.');
    });

    test('recently done: moves on to the next lane', () {
      final first = rec(const {});
      expect(first.lane, engine.IdentityLane.aerobic);
      final next = rec(const {}, [
        run('a', 1, template: engine.SessionSpec.norwegian4x4Id),
      ]);
      expect(next.lane, engine.IdentityLane.speed);
      // Done a while ago: it is the recommendation again.
      final later = rec(const {}, [
        run('a', 6, template: engine.SessionSpec.norwegian4x4Id),
      ]);
      expect(later.lane, engine.IdentityLane.aerobic);
    });

    test('every lane done recently: the one done longest ago', () {
      final runs = [
        run('a', 1, template: engine.SessionSpec.norwegian4x4Id),
        run('s', 2, template: '400s'),
        run('m', 0, m: 16000),
      ];
      // aerobic 1 day, speed 2 days, mid and long 0 days: speed is oldest.
      final r = rec(const {}, runs);
      expect(r.lane, engine.IdentityLane.speed);
    });

    test('ordinals', () {
      String o(int n) => '$n${ScoreNorms.ordinalSuffix(n)}';
      expect(
        [
          for (final n in [1, 2, 3, 4, 11, 12, 13, 21, 22, 60, 99]) o(n),
        ],
        [
          '1st',
          '2nd',
          '3rd',
          '4th',
          '11th',
          '12th',
          '13th',
          '21st',
          '22nd',
          '60th',
          '99th',
        ],
      );
    });

    test('Start preset follows the recommendation', () {
      const base = AppSettings(lastMode: RecordMode.cooper, goalRun: true);
      final speed = rec(const {}, [
        run('a', 1, template: engine.SessionSpec.norwegian4x4Id),
      ]).apply(base);
      expect(speed.lastMode, RecordMode.intervals);
      expect(speed.goalRun, isFalse);
      expect(speed.sessionId, '400s');

      final mid = rec({
        ...all(),
        engine.IdentityLane.mid: score(engine.IdentityLane.mid, daysAgo: 30),
      }).apply(const AppSettings());
      expect(mid.goalRun, isTrue);
      expect(mid.goalId, 'd5000');

      final long = rec({...all()}..remove(engine.IdentityLane.long))
          .apply(base);
      expect(long.lastMode, RecordMode.free);
      expect(long.goalRun, isFalse);
    });
  });
}
