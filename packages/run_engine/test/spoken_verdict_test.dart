import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'trail_verdict_test.dart' show route, run;

Verdict verdict(VerdictHeadline h, {bool best = false}) => Verdict(
  stage: VerdictStage.vsMedian,
  headline: h,
  subline: 'x',
  floorSecPerKm: 10,
  bandSecPerKm: 10,
  engineVersion: 1,
  computedAt: DateTime(2026, 10, 3),
  bestIn365Days: best,
);

void main() {
  group('session verdict (4x4): the on-screen headline, said', () {
    test('every headline matches the screen text, sentence case', () {
      for (final h in [
        VerdictHeadline.faster,
        VerdictHeadline.holding,
        VerdictHeadline.slower,
        VerdictHeadline.noRealChange,
        VerdictHeadline.baselineSet,
      ]) {
        final said = SpokenVerdict.ofSession(verdict(h))!;
        expect(said.toLowerCase(), '${h.text.toLowerCase()}.');
        expect(said[0], said[0].toUpperCase());
        expect(said, isNot(contains('—')));
      }
    });

    test('no verdict and indoor say nothing', () {
      expect(SpokenVerdict.ofSession(null), isNull);
      expect(
        SpokenVerdict.ofSession(verdict(VerdictHeadline.noVerdict)),
        isNull,
      );
      expect(
        SpokenVerdict.ofSession(verdict(VerdictHeadline.indoorRun)),
        isNull,
      );
    });

    test('a 365-day best adds the new-best line', () {
      expect(
        SpokenVerdict.ofSession(
          verdict(VerdictHeadline.faster, best: true),
          sessionName: 'Norwegian 4x4',
        ),
        'Faster. New best Norwegian 4x4.',
      );
      expect(
        SpokenVerdict.ofSession(verdict(VerdictHeadline.holding, best: true)),
        'Holding. New best.',
      );
    });
  });

  group('trail verdict', () {
    final loop = route();
    final d = DateTime(2026, 9, 12, 7);
    final d2 = DateTime(2026, 9, 20, 7);

    test('faster on the same trail names the gap, like the screen', () {
      final r = TrailVerdict.of(run('b', d2, 2470, r: loop), [
        run('a', d, 2600, r: loop),
      ]);
      expect(r.headline, 'FASTER ON THIS TRAIL');
      expect(
        SpokenVerdict.ofTrail(r),
        'Faster on this trail, 2 minutes 10 quicker than last time.',
      );
    });

    test('slower on the same trail', () {
      final r = TrailVerdict.of(run('b', d2, 2600, r: loop), [
        run('a', d, 2470, r: loop),
      ]);
      expect(
        SpokenVerdict.ofTrail(r),
        'Slower on this trail, 2 minutes 10 slower than last time.',
      );
    });

    test('level on the same trail', () {
      final r = TrailVerdict.of(run('b', d2, 2600, r: loop), [
        run('a', d, 2605, r: loop),
      ]);
      expect(r.headline, 'NO REAL CHANGE');
      expect(SpokenVerdict.ofTrail(r), 'No real change.');
    });

    test(
      'effort pace and baseline say the headline; no elevation says nothing',
      () {
        final base = TrailVerdict.of(run('a', d, 2600), const []);
        expect(base.headline, 'BASELINE SET');
        expect(SpokenVerdict.ofTrail(base), 'Baseline set.');
        final none = TrailVerdict.of(run('a', d, 2600, gap: null), const []);
        expect(SpokenVerdict.ofTrail(none), isNull);
      },
    );
  });

  test('gapWords: the same rule as the cue gaps', () {
    expect(SpokenVerdict.gapWords(1), '1 second');
    expect(SpokenVerdict.gapWords(17), '17 seconds');
    expect(SpokenVerdict.gapWords(60), '1 minute');
    expect(SpokenVerdict.gapWords(137), '2 minutes 17');
  });
}
