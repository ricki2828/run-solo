import '../model/run_file.dart' show Units;
import '../weather/heat_model.dart';
import 'block_plan.dart';
import 'elevation.dart';
import 'event_names.dart';
import 'fitness_hero.dart';
import 'format.dart';
import 'hr_zones.dart';
import 'live_plan.dart';

/// The four session intensities that carry a target pace.
enum PaceIntensity {
  easy('Easy', 'easy'),
  tempo('Tempo', 'tempo'),
  threshold('Threshold', 'threshold'),
  vo2max('VO2 max', 'VO2 max');

  const PaceIntensity(this.label, this.word);
  final String label;

  /// Lower-case wording inside a sentence.
  final String word;

  /// The heart-rate zones that mean this effort, for a grade steep enough
  /// to make pace meaningless: (lowest, highest).
  (int, int) get zones => switch (this) {
    PaceIntensity.easy => (1, 2),
    PaceIntensity.tempo => (3, 3),
    PaceIntensity.threshold => (4, 4),
    PaceIntensity.vo2max => (5, 5),
  };

  static PaceIntensity? byName(String? n) {
    for (final i in values) {
      if (i.name == n) return i;
    }
    return null;
  }
}

/// One target pace: a True Pace (flat, cool day) in s/km, and where it came
/// from. Estimates, not prescriptions.
class TargetPace {
  const TargetPace({
    required this.intensity,
    required this.trueSecPerKm,
    required this.method,
    this.modelSecPerKm,
  });

  final PaceIntensity intensity;

  /// The pace in force: the runner's accepted nudge when there is one, else
  /// [modelSecPerKm].
  final double trueSecPerKm;

  /// What the VDOT tables say, whether or not a nudge moved the target.
  final double? modelSecPerKm;

  /// "Pace you could hold for about an hour (Daniels-Gilbert VDOT)", plus
  /// " · moved by you" for an accepted nudge.
  final String method;

  bool get adopted =>
      modelSecPerKm != null && (trueSecPerKm - modelSecPerKm!).abs() > 0.5;
}

/// A target after today's conditions: a pace to run, or an effort to run
/// by when pace would mislead (a steep grade, or too hot to compare).
class AdjustedPace {
  const AdjustedPace({
    required this.target,
    this.secPerKm,
    this.effort,
    this.notes = const [],
  });

  final TargetPace target;

  /// The actual pace to run today; null when [effort] stands in.
  final double? secPerKm;

  /// "Zone 4 effort (148 to 162 bpm)" when pace is not the right guide.
  final String? effort;

  /// "heat +12 s/km", "climb +40 s/km".
  final List<String> notes;

  bool get isEffort => secPerKm == null;
}

/// Session target paces from the runner's own recent runs.
///
/// The fitness figure is the Home hero's VDOT (Daniels-Gilbert), taken from
/// the best run of the last 6 weeks at its True Pace, so hills and heat are
/// already out of it and trail runs count. From it:
///
/// - Threshold: the pace you could hold for about an hour (VDOT race
///   equivalence).
/// - Tempo: the half-marathon equivalent (VDOT race equivalence).
/// - VO2 max: the 3 km equivalent, the pace of the 4x4 and similar sets.
/// - Easy: 25% slower than threshold, a common rule of thumb; a ceiling,
///   slower is fine.
///
/// Public methods only (VDOT equivalence, Riegel behind the predictor,
/// Minetti grade cost, Hadley heat table). All figures are True Pace until
/// [adjust] puts today's heat and grade back.
class TargetPaces {
  const TargetPaces._({
    required this.vdot,
    required this.sourceLine,
    required this.paces,
  });

  final double vdot;

  /// "From your 5K on 12 Sep".
  final String sourceLine;
  final Map<PaceIntensity, TargetPace> paces;

  static const String vdotMethod = 'Daniels-Gilbert VDOT';

  static const Map<PaceIntensity, String> methods = {
    PaceIntensity.easy: 'Easy: 25% slower than your threshold pace (rule of thumb); slower is fine',
    PaceIntensity.tempo:
        'Tempo: your half-marathon equivalent ($vdotMethod race equivalence)',
    PaceIntensity.threshold:
        'Threshold: the pace you could hold for about an hour ($vdotMethod)',
    PaceIntensity.vo2max:
        'VO2 max: your 3 km equivalent pace ($vdotMethod race equivalence)',
  };

  static const List<String> method = [
    'Targets come from your best run in the last 6 weeks, taken to true '
        'pace (hills and heat out), so trail runs count. The Daniels-Gilbert '
        'VDOT turns that run into a fitness figure and the pace you could '
        'hold at each effort.',
    'Today\'s heat comes from the forecast (Hadley\'s table) and climbs from '
        'the grade (Minetti\'s running cost). On a steep grade the target is '
        'a heart-rate zone instead. Estimates, not promises.',
  ];

  TargetPace? operator [](PaceIntensity i) => paces[i];

  /// Targets over [runs], with the runner's accepted paces in [adopted]
  /// (intensity to true s/km). Null with no fitness figure to go on.
  static TargetPaces? of(
    Iterable<LiveCandidate> runs, {
    required DateTime now,
    EventNames names = EventNames.generic,
    Map<PaceIntensity, double> adopted = const {},
    Map<PaceIntensity, double> adoptedFrom = const {},
  }) {
    final hero = FitnessHero.of(runs, now: now, names: names);
    if (hero == null) return null;
    return fromVdot(
      hero.vo2,
      sourceLine: _sourceLine(hero),
      adopted: adopted,
      adoptedFrom: adoptedFrom,
    );
  }

  static TargetPaces? fromVdot(
    double vdot, {
    String sourceLine = '',
    Map<PaceIntensity, double> adopted = const {},
    Map<PaceIntensity, double> adoptedFrom = const {},
  }) {
    final th = BlockPaces.threshold(vdot);
    final half = BlockPaces.race(vdot, 21097.5);
    final vo2 = BlockPaces.race(vdot, 3000);
    if (th == null || half == null || vo2 == null) return null;
    final model = {
      PaceIntensity.easy: th * 1.25,
      PaceIntensity.tempo: half,
      PaceIntensity.threshold: th,
      PaceIntensity.vo2max: vo2,
    };
    // An accepted pace stands only until the tables catch up with it: once
    // the model is at or past the adopted pace (from the side it started on),
    // the move has done its job and the tables take over again.
    double? kept(PaceIntensity i) {
      final a = adopted[i];
      if (a == null) return null;
      final from = adoptedFrom[i];
      if (from == null) return a;
      final m = model[i]!;
      if (a < from && m <= a) return null;
      if (a > from && m >= a) return null;
      return a;
    }

    return TargetPaces._(
      vdot: vdot,
      sourceLine: sourceLine,
      paces: {
        for (final e in model.entries)
          e.key: TargetPace(
            intensity: e.key,
            modelSecPerKm: e.value,
            trueSecPerKm: kept(e.key) ?? e.value,
            method:
                '${methods[e.key]}'
                '${kept(e.key) == null ? '' : ' · moved by you'}',
          ),
      },
    );
  }

  /// Whether the target behind [sessionPace] is one the runner moved by
  /// accepting a nudge (so the method label says "moved by you").
  bool sessionPaceMoved(BlockSession s) {
    final i = switch (s.kind) {
      BlockKind.easy || BlockKind.long => PaceIntensity.easy,
      BlockKind.goal => null,
      BlockKind.interval => switch (s.presetId) {
        'tempo' => PaceIntensity.tempo,
        '1km-repeats' || '400s' => null,
        _ => PaceIntensity.vo2max,
      },
    };
    return i != null && (paces[i]?.adopted ?? false);
  }

  /// The True Pace a plan session aims at, from these same targets (so an
  /// accepted nudge and trail-run fitness count): easy and long sit on the
  /// easy target, tempo on the tempo target, VO2 sets on the VO2 target;
  /// the 5K goal and the short-rep presets are race equivalents of [vdot].
  double? sessionPace(BlockSession s) {
    switch (s.kind) {
      case BlockKind.easy:
        return paces[PaceIntensity.easy]?.trueSecPerKm;
      case BlockKind.long:
        final e = paces[PaceIntensity.easy]?.trueSecPerKm;
        return e == null ? null : e * 1.2 / 1.25;
      case BlockKind.goal:
        return BlockPaces.race(vdot, 5000);
      case BlockKind.interval:
        return switch (s.presetId) {
          'tempo' => paces[PaceIntensity.tempo]?.trueSecPerKm,
          '1km-repeats' => BlockPaces.race(vdot, 5000),
          '400s' => BlockPaces.race(vdot, 1500),
          _ => paces[PaceIntensity.vo2max]?.trueSecPerKm,
        };
    }
  }

  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String _sourceLine(FitnessHero h) {
    final d = h.asOf;
    final when = '${_days[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';
    return h.sourceLabel == 'Cooper test'
        ? 'From your Cooper test on $when'
        : 'From your ${h.sourceLabel} on $when';
  }

  /// Climbs and descents steeper than this make pace the wrong guide.
  static const double steepGradePct = 8;

  /// Below this a grade is noise (the True Pace deadband).
  static const double flatGradePct = 0.5;

  /// [pace] for today: heat from [tempC] and [dewPointC], and the sustained
  /// grade [gradePct] (+ uphill) of the stretch. Returns an effort by
  /// heart-rate zone when the grade is steep or it is too hot to compare.
  ///
  /// [runMetres] is how far the run goes: heat builds with distance (the
  /// display ramp, none under 3 km, all of it from 9 km), so a short rep set
  /// gets little. Without it the full heat is shown, labelled "up to".
  static AdjustedPace adjust(
    TargetPace pace, {
    double? tempC,
    double? dewPointC,
    double? gradePct,
    double? runMetres,
    HrZones? zones,
  }) {
    final notes = <String>[];
    var actual = pace.trueSecPerKm;
    var effort = false;
    final grade = gradePct ?? 0;
    if (grade.abs() >= steepGradePct) {
      effort = true;
      notes.add(
        '${grade > 0 ? 'steep climb' : 'steep descent'}, pace misleads',
      );
    } else if (grade.abs() >= flatGradePct) {
      final before = actual;
      actual *= Gap.ratio(grade / 100);
      notes.add(
        '${grade > 0 ? 'climb' : 'descent'} '
        '${_signed((actual - before).round())} s/km',
      );
    }
    if (tempC != null && dewPointC != null) {
      final f = HeatModel.of(tempC: tempC, dewPointC: dewPointC).fraction;
      if (f == null) {
        effort = true;
        notes.add('too hot to compare');
      } else {
        final share = runMetres == null
            ? 1.0
            : HeatModel.distanceRamp(runMetres);
        final fe = f * share;
        if (fe >= 0.005) {
          final before = actual;
          actual /= 1 - fe;
          notes.add(
            'heat ${runMetres == null ? 'up to ' : ''}'
            '${_signed((actual - before).round())} s/km',
          );
        }
      }
    }
    if (!effort) {
      return AdjustedPace(target: pace, secPerKm: actual, notes: notes);
    }
    return AdjustedPace(
      target: pace,
      effort: effortLine(pace.intensity, zones),
      notes: notes,
    );
  }

  static String _signed(int s) => s >= 0 ? '+$s' : '$s';

  /// "Zone 4 effort (148 to 162 bpm)", or just "Zone 4 effort" without zones.
  static String effortLine(PaceIntensity i, [HrZones? zones]) {
    final (lo, hi) = i.zones;
    final name = lo == hi ? 'Zone $lo' : 'Zones $lo and $hi';
    if (zones == null) return '$name effort';
    final top = zones.top(hi);
    final bpm = top == null
        ? '${zones.bottom(lo).round()} bpm and up'
        : '${zones.bottom(lo).round()} to $top bpm';
    return '$name effort ($bpm)';
  }

  /// "4:17/km" for a pace target.
  static String paceText(double secPerKm, Units units) =>
      PaceFormat.pace(secPerKm, units);

  /// Pace rounded to the nearest [step] seconds, for a nudge.
  static double roundTo(double secPerKm, [int step = 5]) =>
      (secPerKm / step).round() * step.toDouble();
}

/// One run that tells us how the runner really does at an intensity: its
/// True Pace for that kind of effort.
class PaceObservation {
  const PaceObservation({
    required this.runId,
    required this.date,
    required this.trueSecPerKm,
  });

  final String runId;
  final DateTime date;
  final double trueSecPerKm;
}

/// A suggested move for one target, offered on a tap. Never applied by the
/// engine: [TargetPaces.of] only moves when the caller passes the accepted
/// pace in `adopted`.
class PaceNudge {
  const PaceNudge({
    required this.intensity,
    required this.fromSecPerKm,
    required this.toSecPerKm,
    required this.runCount,
    required this.latestRunDate,
  });

  final PaceIntensity intensity;
  final double fromSecPerKm;
  final double toSecPerKm;

  /// The runs behind it.
  final int runCount;
  final DateTime latestRunDate;

  bool get quicker => toSecPerKm < fromSecPerKm;

  /// "Your easy pace looks quicker now: 5:20 to 5:10?"
  String line(Units units) =>
      'Your ${intensity.word} pace looks ${quicker ? 'quicker' : 'slower'} '
      'now: ${PaceFormat.paceBare(fromSecPerKm, units)} to '
      '${PaceFormat.paceBare(toSecPerKm, units)}?';

  /// "Your last 4 runs at this effort were all quicker than the target."
  String get why =>
      'Your last $runCount ${intensity.word} efforts were all '
      '${quicker ? 'quicker' : 'slower'} than the target.';
}

/// When to offer a [PaceNudge]: only on sustained evidence, never twice in a
/// breath, never back and forth.
abstract final class PaceNudges {
  /// Runs older than this are not evidence.
  static const int windowDays = 42;

  /// Runs this far off the target (either way) are a different kind of day
  /// (a bad GPS spike, a walk break), not evidence.
  static const double outlierFraction = 0.15;

  /// The most recent runs considered.
  static const int take = 5;

  /// Evidence needed: easy is noisiest.
  static int minRuns(PaceIntensity i) => i == PaceIntensity.easy ? 4 : 3;

  /// Every kept run must be at least this far off, in the same direction.
  static const double perRunFraction = 0.01;

  /// And the median at least this far (2.5% is about 8 s/km at 5:20).
  static const double medianFraction = 0.025;

  /// The runs must span at least this many days: one block of work is not
  /// a trend.
  static const int minSpanDays = 10;

  /// After any answer, taken or not, stay quiet this long.
  static const int cooldownDays = 21;

  /// Against the direction of the last accepted move the bar doubles.
  static const double reverseFactor = 2;

  /// A nudge for [intensity], or null. [current] is the target in force.
  /// [observations] are the runner's runs at this effort; only those after
  /// [lastAnswerAt] (when they last tapped Yes or Keep) count.
  /// [lastAcceptedQuicker] is the direction of the last accepted move.
  static PaceNudge? evaluate(
    PaceIntensity intensity, {
    required double current,
    required Iterable<PaceObservation> observations,
    required DateTime now,
    DateTime? lastAnswerAt,
    bool? lastAcceptedQuicker,
  }) {
    if (!current.isFinite || current <= 0) return null;
    if (lastAnswerAt != null &&
        now.difference(lastAnswerAt).inDays < cooldownDays) {
      return null;
    }
    final since = DateTime(now.year, now.month, now.day - windowDays);
    final recent = [
      for (final o in observations)
        if (!o.date.isBefore(since) &&
            !o.date.isAfter(now) &&
            (lastAnswerAt == null || o.date.isAfter(lastAnswerAt)) &&
            o.trueSecPerKm.isFinite &&
            ((o.trueSecPerKm - current).abs() / current) <= outlierFraction)
          o,
    ]..sort((a, b) => b.date.compareTo(a.date));
    final used = recent.take(take).toList();
    if (used.length < minRuns(intensity)) return null;
    final devs = [for (final o in used) (o.trueSecPerKm - current) / current];
    final quicker = devs.every((d) => d <= -perRunFraction);
    final slower = devs.every((d) => d >= perRunFraction);
    if (!quicker && !slower) return null;
    // Easy is a ceiling: running it slower than the target is the point.
    if (slower && intensity == PaceIntensity.easy) return null;
    final span = used.first.date.difference(used.last.date).inDays;
    if (span < minSpanDays) return null;
    final paces = [for (final o in used) o.trueSecPerKm]..sort();
    final m = paces.length ~/ 2;
    final median = paces.length.isOdd
        ? paces[m]
        : (paces[m - 1] + paces[m]) / 2;
    var bar = medianFraction;
    if (lastAcceptedQuicker != null && lastAcceptedQuicker != quicker) {
      bar *= reverseFactor;
    }
    if ((median - current).abs() / current < bar) return null;
    final to = TargetPaces.roundTo(median);
    if ((to - current).abs() < 5) return null;
    return PaceNudge(
      intensity: intensity,
      fromSecPerKm: TargetPaces.roundTo(current),
      toSecPerKm: to,
      runCount: used.length,
      latestRunDate: used.first.date,
    );
  }
}
