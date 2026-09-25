import 'metrics.dart';

/// The user-level observed-max state the store keeps in settings (plan D3,
/// §18.11 N1): the highest sustained 30 s HR ever accepted, plus one value
/// held back by the artefact guard awaiting the user's answer.
///
/// Immutable; every transition is a pure function on [ObservedMaxHrGuard] so
/// the precedence table in D3 is fixture-tested without a widget.
class ObservedMaxHrState {
  const ObservedMaxHrState({this.observed, this.pending});

  /// Accepted observed 30 s max, or null before any strap run.
  final double? observed;

  /// A 30 s value above the guard, offered once ("Strap saw 201 bpm for
  /// 30 s. Use it as your max?"). Not used by [MetricsCalculator.maxHrFor]
  /// until confirmed.
  final double? pending;

  static const ObservedMaxHrState none = ObservedMaxHrState();

  bool get hasPending => pending != null;

  /// The profile field the resolver reads: only the accepted value.
  UserProfile profile({int? maxHr, int? age}) =>
      UserProfile(maxHr: maxHr, age: age, observedMaxHr: observed);

  Map<String, Object?> toJson() => {'observed': observed, 'pending': pending};

  factory ObservedMaxHrState.fromJson(Map<String, Object?> json) {
    double? readNum(String k) {
      final v = json[k];
      return v is num ? v.toDouble() : null;
    }

    return ObservedMaxHrState(
      observed: readNum('observed'),
      pending: readNum('pending'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ObservedMaxHrState &&
      other.observed == observed &&
      other.pending == pending;

  @override
  int get hashCode => Object.hash(observed, pending);

  @override
  String toString() => 'ObservedMaxHrState($observed, pending $pending)';
}

/// Artefact guard for observed max HR (D3 item 5). A single 30 s strap
/// artefact (dry contact, a spike) could otherwise raise max HR for good.
class ObservedMaxHrGuard {
  const ObservedMaxHrGuard({
    this.marginBpm = 15,
    this.absoluteCeilingBpm = 220,
  });

  /// An observed value more than this above the reference is held pending.
  /// The reference is the typed max HR, or an already-accepted observed max
  /// when that is higher (a confirmed 205 must not re-prompt on 206).
  final double marginBpm;

  /// Nothing above this is ever applied silently.
  final double absoluteCeilingBpm;

  static const ObservedMaxHrGuard defaults = ObservedMaxHrGuard();

  /// Fold one run's highest 30 s HR ([FourByFourMetrics.observedMaxHrThisRun]
  /// or [LapsSummary.observedMaxHrThisRun]) into the state.
  ///
  /// - null, or not above the accepted value → unchanged;
  /// - above `absoluteCeilingBpm`, or above `typedMaxHr + margin` (with an
  ///   accepted observed max raising that reference) → held as `pending`,
  ///   the accepted value untouched; a higher pending value replaces a
  ///   lower one;
  /// - otherwise accepted at once.
  ///
  /// With no typed value there is no "typed + 15" edge: only the 220
  /// ceiling applies, because 220−age or the 190 fallback are guesses, not
  /// evidence the strap could contradict.
  ObservedMaxHrState fold(
    ObservedMaxHrState state, {
    required double? runObserved30s,
    required int? typedMaxHr,
  }) {
    final value = runObserved30s;
    if (value == null) return state;
    final accepted = state.observed;
    if (accepted != null && value <= accepted) return state;
    final reference = _reference(typedMaxHr, accepted);
    final suspicious =
        value > absoluteCeilingBpm ||
        (reference != null && value > reference + marginBpm);
    if (suspicious) {
      final pending = state.pending;
      if (pending != null && pending >= value) return state;
      return ObservedMaxHrState(observed: accepted, pending: value);
    }
    return ObservedMaxHrState(observed: value, pending: state.pending);
  }

  /// [Use]: the pending value becomes the accepted observed max.
  ObservedMaxHrState confirmPending(ObservedMaxHrState state) {
    final p = state.pending;
    if (p == null) return state;
    final accepted = state.observed;
    return ObservedMaxHrState(
      observed: accepted != null && accepted > p ? accepted : p,
    );
  }

  /// [Ignore]: offered once, so the value is dropped, not re-asked.
  ObservedMaxHrState ignorePending(ObservedMaxHrState state) =>
      ObservedMaxHrState(observed: state.observed);

  /// Settings → Heart rate → "Reset observed max": clears both; the resolver
  /// falls back to typed → 220−age → 190.
  ObservedMaxHrState reset(ObservedMaxHrState state) => ObservedMaxHrState.none;

  double? _reference(int? typedMaxHr, double? accepted) {
    final typed = typedMaxHr?.toDouble();
    if (typed == null) return accepted;
    if (accepted == null) return typed;
    return accepted > typed ? accepted : typed;
  }
}
