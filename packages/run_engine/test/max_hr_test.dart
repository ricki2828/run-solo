import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

/// Plan D3 (§16 decision 3, §18.11 N1): one max-HR resolver, observed wins,
/// artefact guard, reset.
void main() {
  double resolve({int? typed, int? age, double? observed}) =>
      MetricsCalculator.maxHrFor(
        UserProfile(maxHr: typed, age: age, observedMaxHr: observed),
      );

  group('maxHrFor precedence table (D3)', () {
    test(
      'typed 185 + observed 192 → 192 (observed wins over a lower typed)',
      () {
        expect(resolve(typed: 185, observed: 192), 192);
      },
    );
    test('typed 185 + observed 180 → 185', () {
      expect(resolve(typed: 185, observed: 180), 185);
    });
    test('none + age 40 + observed 192 → 192', () {
      expect(resolve(age: 40, observed: 192), 192);
    });
    test('none + age 40, no observed → 180', () {
      expect(resolve(age: 40), 180);
    });
    test('nothing → 190', () {
      expect(resolve(), 190);
      expect(MetricsCalculator.fallbackMaxHr, 190);
    });
    test(
      'observed 189 with no typed value and no age → 190 (max(190, 189))',
      () {
        expect(resolve(observed: 189), 190);
      },
    );
    test('observed 191 with nothing else → 191', () {
      expect(resolve(observed: 191), 191);
    });
    test('typed wins over age; observed above both wins over both', () {
      expect(resolve(typed: 170, age: 30), 170);
      expect(resolve(typed: 170, age: 30, observed: 195), 195);
    });
    test('never null: zones always resolve', () {
      expect(resolve(), isA<double>());
    });
  });

  group('artefact guard (D3 item 5)', () {
    const guard = ObservedMaxHrGuard.defaults;
    const none = ObservedMaxHrState.none;

    test('typed 185 + observed 199 → applied automatically (inside +15)', () {
      final s = guard.fold(none, runObserved30s: 199, typedMaxHr: 185);
      expect(s.observed, 199);
      expect(s.pending, isNull);
      expect(resolve(typed: 185, observed: s.observed), 199);
    });

    test('typed 185 + observed 200 → applied (the edge is inclusive)', () {
      final s = guard.fold(none, runObserved30s: 200, typedMaxHr: 185);
      expect(s.observed, 200);
    });

    test(
      'typed 185 + observed 201 → pending; resolver stays 185 until confirmed',
      () {
        final s = guard.fold(none, runObserved30s: 201, typedMaxHr: 185);
        expect(s.observed, isNull);
        expect(s.pending, 201);
        expect(resolve(typed: 185, observed: s.observed), 185);
        final confirmed = guard.confirmPending(s);
        expect(confirmed.observed, 201);
        expect(confirmed.pending, isNull);
        expect(resolve(typed: 185, observed: confirmed.observed), 201);
      },
    );

    test('observed 225 → pending even with no typed value (above 220)', () {
      final s = guard.fold(none, runObserved30s: 225, typedMaxHr: null);
      expect(s.observed, isNull);
      expect(s.pending, 225);
      expect(resolve(age: 40, observed: s.observed), 180);
    });

    group('no typed max: default + 10, or 200, is the guard (follow-up)', () {
      test('age 60: a 10 s burst lifting a window to 172 is held pending, '
          'not silently over 220−60', () {
        final s = guard.fold(
          none,
          runObserved30s: 172,
          typedMaxHr: null,
          age: 60,
        );
        expect(s.observed, isNull);
        expect(s.pending, 172);
        expect(resolve(age: 60, observed: s.observed), 160);
        final confirmed = guard.confirmPending(s);
        expect(resolve(age: 60, observed: confirmed.observed), 172);
      });

      test('age 60: a genuine sustained 168 (inside +10) applies', () {
        final s = guard.fold(
          none,
          runObserved30s: 168,
          typedMaxHr: null,
          age: 60,
        );
        expect(s.observed, 168);
        expect(s.pending, isNull);
        expect(resolve(age: 60, observed: s.observed), 168);
      });

      test('age 40: 190 applies (edge inclusive), 191 pending', () {
        expect(
          guard
              .fold(none, runObserved30s: 190, typedMaxHr: null, age: 40)
              .observed,
          190,
        );
        final s = guard.fold(
          none,
          runObserved30s: 191,
          typedMaxHr: null,
          age: 40,
        );
        expect(s.observed, isNull);
        expect(s.pending, 191);
      });

      test('no age: 190 fallback + 10 → 200 applies, 201 pending', () {
        expect(
          guard.fold(none, runObserved30s: 200, typedMaxHr: null).observed,
          200,
        );
        final s = guard.fold(none, runObserved30s: 201, typedMaxHr: null);
        expect(s.observed, isNull);
        expect(s.pending, 201);
      });

      test(
        'age 25 (default 195): 202 is within +10 but above 200 → pending',
        () {
          final s = guard.fold(
            none,
            runObserved30s: 202,
            typedMaxHr: null,
            age: 25,
          );
          expect(s.observed, isNull);
          expect(s.pending, 202);
          expect(
            guard
                .fold(none, runObserved30s: 200, typedMaxHr: null, age: 25)
                .observed,
            200,
          );
        },
      );

      test('an accepted observed max raises the untyped reference', () {
        var s = guard.fold(
          none,
          runObserved30s: 172,
          typedMaxHr: null,
          age: 60,
        );
        s = guard.confirmPending(s);
        s = guard.fold(s, runObserved30s: 180, typedMaxHr: null, age: 60);
        expect(s.observed, 180, reason: '172 + 10 covers 180');
        s = guard.fold(s, runObserved30s: 195, typedMaxHr: null, age: 60);
        expect(s.observed, 180);
        expect(s.pending, 195);
      });

      test('a typed max keeps the +15 rule and ignores age', () {
        final s = guard.fold(
          none,
          runObserved30s: 199,
          typedMaxHr: 185,
          age: 60,
        );
        expect(s.observed, 199);
        expect(
          guard
              .fold(none, runObserved30s: 205, typedMaxHr: 185, age: 60)
              .pending,
          205,
        );
      });
    });

    test('[Ignore] drops the pending value; it is offered once', () {
      final s = guard.fold(none, runObserved30s: 201, typedMaxHr: 185);
      final ignored = guard.ignorePending(s);
      expect(ignored, none);
      // The same run folded again would ask again; the store folds a run
      // once, after finalise, so this is the app's contract, not ours.
    });

    test('a confirmed 205 does not re-prompt on 206 (reference moves up)', () {
      var s = guard.fold(none, runObserved30s: 205, typedMaxHr: 185);
      s = guard.confirmPending(s);
      expect(s.observed, 205);
      s = guard.fold(s, runObserved30s: 206, typedMaxHr: 185);
      expect(s.observed, 206);
      expect(s.pending, isNull);
    });

    test('a value not above the accepted max changes nothing', () {
      const s = ObservedMaxHrState(observed: 192);
      expect(guard.fold(s, runObserved30s: 190, typedMaxHr: 185), s);
      expect(guard.fold(s, runObserved30s: 192, typedMaxHr: 185), s);
      expect(guard.fold(s, runObserved30s: null, typedMaxHr: 185), s);
    });

    test('a higher pending replaces a lower one; a lower one is ignored', () {
      var s = guard.fold(none, runObserved30s: 201, typedMaxHr: 185);
      s = guard.fold(s, runObserved30s: 203, typedMaxHr: 185);
      expect(s.pending, 203);
      s = guard.fold(s, runObserved30s: 202, typedMaxHr: 185);
      expect(s.pending, 203);
    });

    test('an in-guard value applies while a higher one stays pending', () {
      var s = guard.fold(none, runObserved30s: 210, typedMaxHr: 185);
      s = guard.fold(s, runObserved30s: 195, typedMaxHr: 185);
      expect(s.observed, 195);
      expect(s.pending, 210);
      // Confirming keeps the higher of the two.
      expect(guard.confirmPending(s).observed, 210);
    });

    test('reset clears observed and pending; the resolver falls back', () {
      var s = guard.fold(none, runObserved30s: 199, typedMaxHr: 185);
      s = guard.fold(s, runObserved30s: 215, typedMaxHr: 185);
      expect(s.observed, 199);
      expect(s.pending, 215);
      final r = guard.reset(s);
      expect(r, none);
      expect(resolve(typed: 185, observed: r.observed), 185);
      expect(resolve(age: 40, observed: r.observed), 180);
      expect(resolve(observed: r.observed), 190);
    });

    test('state round-trips through JSON for settings.json', () {
      const s = ObservedMaxHrState(observed: 199.5, pending: 215);
      expect(ObservedMaxHrState.fromJson(s.toJson()), s);
      expect(ObservedMaxHrState.fromJson(const {}), none);
      expect(
        ObservedMaxHrState.fromJson(const {'observed': 190}),
        const ObservedMaxHrState(observed: 190),
      );
    });

    test('profile() exposes only the accepted value to the resolver', () {
      const s = ObservedMaxHrState(observed: 192, pending: 230);
      final p = s.profile(maxHr: 185, age: 40);
      expect(p.observedMaxHr, 192);
      expect(p.maxHr, 185);
      expect(MetricsCalculator.maxHrFor(p), 192);
    });
  });

  group('the engine reads the resolver, never settings raw', () {
    test('a 4x4 with HR and no profile uses the 190 fallback for zones', () {
      // Covered end to end in recompute_test ("max HR precedence and time
      // in zone"); here only the pinned constant.
      expect(MetricsCalculator.maxHrFor(UserProfile.none), 190);
    });
  });
}
