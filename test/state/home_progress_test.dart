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

void main() {
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
      expect(h.line, contains('A clean interval session brings it back.'));
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
      expect(r.startLabel, 'Start 8 × 400 m');
    });

    test('missing lane comes first and says what unlocks it', () {
      final s = {...all()}..remove(engine.IdentityLane.long);
      final r = rec(s);
      expect(r.lane, engine.IdentityLane.long);
      expect(r.reason, 'LONG needs a 15K+ run to count.');
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
