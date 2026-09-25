/// One max-HR resolver for the whole app (plan D3, §18.11 INFO/N1):
/// `max(typed ?? 220 − age ?? 190, observed 30 s max)`, observed winning over
/// any lower entered value. The artefact guard (D3 rule 5) is applied when a
/// run's observed value is folded in: more than 15 above the typed max, or
/// above 220, is held as `pending` and offered once as a confirm sheet.
library;

import 'package:flutter/foundation.dart';
import 'package:run_engine/run_engine.dart' as engine;

import 'settings.dart';

enum MaxHrSource { typed, age, fallback, observed }

@immutable
class MaxHrResolution {
  const MaxHrResolution({
    required this.maxHr,
    required this.source,
    required this.base,
    this.observedAt,
  });

  final int maxHr;
  final MaxHrSource source;

  /// The typed / age / fallback number before the observed value was applied.
  final int base;
  final DateTime? observedAt;
}

abstract final class MaxHr {
  static int ageFor(int birthYear, DateTime now) => now.year - birthYear;

  /// What the engine reads (its `maxHrFor` does the same max()).
  static engine.UserProfile profileFor(AppSettings s, DateTime now) =>
      engine.UserProfile(
        age: s.birthYear == null ? null : ageFor(s.birthYear!, now),
        maxHr: s.typedMaxHr,
        observedMaxHr: s.observedMaxHr?.toDouble(),
      );

  static MaxHrResolution resolve(AppSettings s, DateTime now) {
    final int base;
    final MaxHrSource baseSource;
    if (s.typedMaxHr != null) {
      base = s.typedMaxHr!;
      baseSource = MaxHrSource.typed;
    } else if (s.birthYear != null) {
      base = 220 - ageFor(s.birthYear!, now);
      baseSource = MaxHrSource.age;
    } else {
      base = MaxHrRules.fallback;
      baseSource = MaxHrSource.fallback;
    }
    final observed = s.observedMaxHr;
    // The number itself is the engine's resolver (one `maxHrFor`, D3 N1).
    assert(
      engine.MetricsCalculator.maxHrFor(profileFor(s, now)).round() ==
          (observed != null && observed > base ? observed : base),
      'UI max HR source label disagrees with the engine resolver',
    );
    if (observed != null && observed > base) {
      return MaxHrResolution(
        maxHr: observed,
        source: MaxHrSource.observed,
        base: base,
        observedAt: s.observedMaxHrAt,
      );
    }
    return MaxHrResolution(maxHr: base, source: baseSource, base: base);
  }

  /// Fold a run's highest 30 s HR into settings. Returns the new settings,
  /// unchanged when nothing beats the stored value. Guard: above `typed + 15`
  /// (typed only) or above 220 goes to `pending` instead.
  static AppSettings foldObserved(
    AppSettings s,
    double? observedThisRun,
    DateTime at,
  ) {
    if (observedThisRun == null) return s;
    final before = engine.ObservedMaxHrState(
      observed: s.observedMaxHr?.toDouble(),
      pending: s.pendingObservedMaxHr?.toDouble(),
    );
    final after = engine.ObservedMaxHrGuard.defaults.fold(
      before,
      runObserved30s: observedThisRun,
      typedMaxHr: s.typedMaxHr,
    );
    if (after == before) return s;
    return s.copyWith(
      observedMaxHr: after.observed?.round(),
      observedMaxHrAt: after.observed != before.observed ? at : null,
      pendingObservedMaxHr: after.pending?.round(),
      clearPendingObservedMaxHr: after.pending == null,
    );
  }
}
