import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../platform/gateway.dart';
import 'recording_controller.dart' show RecordingSnapshot;

/// What the in-run moment is about. Order is priority: when one snapshot
/// trips several, the earliest here is shown (the others are consumed).
enum InrunMomentKind {
  goalReached,
  lastStretch,
  halfway,
  repDone,
  distanceMark,
}

/// One brief full-screen moment on the record screen (~1.5 s): a [label]
/// over a big [headline] and a [sub] line. [serial] is unique per moment so
/// a repeat of the same kind restarts the animation.
class InrunMoment {
  const InrunMoment({
    required this.kind,
    required this.label,
    required this.headline,
    required this.serial,
    this.sub,
  });

  final InrunMomentKind kind;

  /// Small caps line over the headline ("REP 2 DONE", "KM").
  final String label;

  /// The big number or word ("4:46", "3", "HALFWAY").
  final String headline;
  final String? sub;
  final int serial;
}

/// The last 400 m of a distance step, or the last minute of a timed one:
/// the record screen's to-go accent, and the "last 400 m" moment.
bool inLastStretch(RecordingSnapshot s) {
  final st = s.currentStep;
  if (st != null && st.target == TargetKind.time) {
    return s.phaseRemainingMs <= 60000;
  }
  final m = s.metresToGo;
  return m != null && m <= 400;
}

/// Watches the snapshots of a live run and says when a moment is due. Pure
/// Dart: it holds counters, never a clock, so tests drive it with snapshots.
///
/// The first snapshot of a run only sets the baselines, so a screen rebuilt
/// mid-run does not replay the marks already passed. Each trigger fires once
/// per run. Only call it for a recording (not paused) snapshot.
class InrunMomentDetector {
  String? _runId;
  int _marks = 0;
  int _reps = 0;
  bool _halfFired = false;
  bool _lastFired = false;
  int _serial = 0;

  /// Metres in the runner's unit: a km or a mile.
  static double unitMetres(Units units) =>
      units == Units.mi ? engine.PaceFormat.metresPerMile : 1000;

  InrunMoment? observe(RecordingSnapshot s, Units units, {bool eased = false}) {
    if (s.runId == null) return null;
    final fresh = s.runId != _runId;
    if (fresh) {
      _runId = s.runId;
      _halfFired = false;
      _lastFired = false;
    }
    final due = <InrunMoment>[];

    // Each km / mile.
    final marks = (s.totalDistanceM / unitMetres(units)).floor();
    if (!fresh && marks > _marks && marks > 0) {
      final unit = units == Units.mi ? 'MI' : 'KM';
      due.add(
        _make(
          InrunMomentKind.distanceMark,
          label: unit,
          headline: '$marks',
          sub: Fmt.clock(s.elapsedMs),
        ),
      );
    }
    _marks = marks;

    // A work rep (or session lap) is complete.
    final paces = s.repPaces;
    final session =
        s.isGoal || s.spec?.templateId == engine.SessionSpec.parkrunId;
    if (s.isPreset && !session && !fresh && paces.length > _reps) {
      final cur = paces.last;
      final earlier = paces.take(paces.length - 1);
      String sub;
      if (earlier.isEmpty) {
        sub = 'first rep in';
      } else {
        final best = earlier.reduce((a, b) => a < b ? a : b);
        final n = Fmt.deltaSecondsVsLast(cur, best, units);
        sub = n == 0
            ? 'level with your best'
            : n < 0
            ? '${-n} s faster than your best'
            : '$n s off your best';
      }
      due.add(
        _make(
          InrunMomentKind.repDone,
          label: 'REP ${paces.length} DONE',
          headline: Fmt.pace(cur, units),
          sub: sub,
        ),
      );
    }
    _reps = paces.length;

    // Goal / event: halfway, last stretch.
    final inGoal = session && s.phase == Phase.work;
    final st = s.currentStep;
    final timed = st?.target == TargetKind.time;
    // A timed step's countdown reads 0 until its first tick.
    final ready = !timed || s.phaseRemainingMs > 0;
    if (inGoal && st != null && ready) {
      final total = timed ? st.value * 1000.0 : st.value.toDouble();
      final done = timed
          ? total - s.phaseRemainingMs
          : (total - (s.metresToGo ?? total));
      if (!_halfFired && total > 0 && done / total >= 0.5) {
        _halfFired = true;
        if (!fresh) {
          due.add(
            _make(
              InrunMomentKind.halfway,
              label: eased ? 'EASY RUN' : 'GOAL',
              headline: 'HALFWAY',
              sub: timed
                  ? '${Fmt.clock(s.phaseRemainingMs)} to go'
                  : '${Fmt.distance(s.metresToGo ?? 0, units)} to go',
            ),
          );
        }
      }
      if (!_lastFired && inLastStretch(s)) {
        _lastFired = true;
        if (!fresh) {
          due.add(
            _make(
              InrunMomentKind.lastStretch,
              label: eased ? 'EASY RUN' : 'GOAL',
              headline: timed ? 'LAST MINUTE' : 'LAST 400 M',
              sub: 'empty the tank',
            ),
          );
        }
      }
    }

    if (due.isEmpty) return null;
    due.sort((a, b) => a.kind.index.compareTo(b.kind.index));
    return due.first;
  }

  /// The goal is reached (the recorder's GoalEvent).
  ///
  /// [eased]: the runner eased off on purpose, so it is an easy run that
  /// reached the distance: no "goal" or "new best" language.
  InrunMoment goalReached(GoalEvent e, {bool eased = false}) => _make(
    InrunMomentKind.goalReached,
    label: eased ? 'DISTANCE DONE' : (e.newBest ? 'NEW BEST' : 'GOAL REACHED'),
    headline: Fmt.clock(e.timeMs),
    sub: e.interrupted ? 'GPS gap, result may be off' : null,
  );

  InrunMoment _make(
    InrunMomentKind kind, {
    required String label,
    required String headline,
    String? sub,
  }) => InrunMoment(
    kind: kind,
    label: label,
    headline: headline,
    sub: sub,
    serial: ++_serial,
  );
}
