import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/state/max_hr.dart';
import 'package:run_solo/state/settings.dart';

/// Plan D3 resolver table and artefact-guard fixtures.
void main() {
  final now = DateTime(2026, 9, 24);
  // age 40 → born 1986
  const born1986 = 1986;

  int resolve(AppSettings s) => MaxHr.resolve(s, now).maxHr;

  test('resolver table (D3)', () {
    expect(
      resolve(const AppSettings(typedMaxHr: 185, observedMaxHr: 192)),
      192,
    );
    expect(
      resolve(const AppSettings(typedMaxHr: 185, observedMaxHr: 180)),
      185,
    );
    expect(
      resolve(const AppSettings(birthYear: born1986, observedMaxHr: 192)),
      192,
    );
    expect(resolve(const AppSettings(birthYear: born1986)), 180);
    expect(resolve(const AppSettings()), 190);
    expect(
      resolve(const AppSettings(observedMaxHr: 189)),
      190,
      reason: 'observed below default',
    );
  });

  test('source line inputs', () {
    expect(
      MaxHr.resolve(const AppSettings(typedMaxHr: 185), now).source,
      MaxHrSource.typed,
    );
    expect(
      MaxHr.resolve(const AppSettings(birthYear: born1986), now).source,
      MaxHrSource.age,
    );
    expect(
      MaxHr.resolve(const AppSettings(), now).source,
      MaxHrSource.fallback,
    );
    final r = MaxHr.resolve(
      AppSettings(
        typedMaxHr: 185,
        observedMaxHr: 192,
        observedMaxHrAt: DateTime(2026, 9, 3),
      ),
      now,
    );
    expect(r.source, MaxHrSource.observed);
    expect(r.observedAt, DateTime(2026, 9, 3));
  });

  test('artefact guard fixtures (D3 rule 5)', () {
    final at = DateTime(2026, 9, 20);
    // typed 185 + observed 199 → 199 auto (within +15)
    var s = MaxHr.foldObserved(const AppSettings(typedMaxHr: 185), 199, at);
    expect(s.observedMaxHr, 199);
    expect(s.pendingObservedMaxHr, isNull);
    // typed 185 + observed 201 → pending, 185 until confirmed
    s = MaxHr.foldObserved(const AppSettings(typedMaxHr: 185), 201, at);
    expect(s.observedMaxHr, isNull);
    expect(s.pendingObservedMaxHr, 201);
    expect(resolve(s), 185);
    // observed 225 → pending (above 220) even with no typed max
    s = MaxHr.foldObserved(const AppSettings(), 225, at);
    expect(s.pendingObservedMaxHr, 225);
    expect(resolve(s), 190);
    // lower than stored → no change
    s = MaxHr.foldObserved(const AppSettings(observedMaxHr: 192), 188.4, at);
    expect(s.observedMaxHr, 192);
    // null → no change
    expect(
      MaxHr.foldObserved(const AppSettings(), null, at).observedMaxHr,
      isNull,
    );
  });

  test('no typed max: the guard uses 220 − age from the birth year', () {
    final at = DateTime(2026, 9, 24);
    const born1966 = 1966; // age 60 → default 160
    // A 10 s burst lifting a 30 s window to 172 is held, not applied.
    final s = MaxHr.foldObserved(
      const AppSettings(birthYear: born1966),
      172,
      at,
    );
    expect(s.observedMaxHr, isNull);
    expect(s.pendingObservedMaxHr, 172);
    expect(MaxHr.resolve(s, at).maxHr, 160);
    // A sustained 168 (inside +10) applies.
    expect(
      MaxHr.foldObserved(
        const AppSettings(birthYear: born1966),
        168,
        at,
      ).observedMaxHr,
      168,
    );
    // No birth year: the 190 reference, so 172 applies.
    expect(MaxHr.foldObserved(const AppSettings(), 172, at).observedMaxHr, 172);
  });

  test('reset clears observed and pending', () {
    const s = AppSettings(observedMaxHr: 192, pendingObservedMaxHr: 205);
    final r = s.copyWith(
      clearObservedMaxHr: true,
      clearPendingObservedMaxHr: true,
    );
    expect(r.observedMaxHr, isNull);
    expect(r.observedMaxHrAt, isNull);
    expect(r.pendingObservedMaxHr, isNull);
  });

  test('engine profile carries age, typed and observed', () {
    final p = MaxHr.profileFor(
      const AppSettings(
        birthYear: born1986,
        typedMaxHr: 185,
        observedMaxHr: 192,
      ),
      now,
    );
    expect(p.age, 40);
    expect(p.maxHr, 185);
    expect(p.observedMaxHr, 192);
  });
}
