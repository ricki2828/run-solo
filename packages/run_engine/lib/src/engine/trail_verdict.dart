import '../model/run_file.dart';
import 'elevation.dart';
import 'format.dart';
import 'route_match.dart';

/// What the same-trail verdict and the trail boards read about one Trail run.
/// Built from the index row alone, never from a run file. [start] is the
/// start as the runner lived it (the local date).
class TrailRunFacts {
  const TrailRunFacts({
    required this.id,
    required this.start,
    required this.movingMs,
    required this.distanceM,
    this.climbM,
    this.gapSecPerKm,
    this.route,
    this.place,
    this.street,
  });

  final String id;
  final DateTime start;
  final int movingMs;
  final double distanceM;
  final double? climbM;

  /// Grade-adjusted pace for the whole run, s/km; null without elevation.
  final double? gapSecPerKm;
  final RouteSignature? route;
  final String? place;
  final String? street;
}

/// Runs that went the same way round the same trail, oldest first. The
/// earliest run is the anchor every later run is matched against, so a trail
/// never drifts as more runs join it.
class TrailGroup {
  const TrailGroup({required this.key, required this.name, required this.runs});

  /// `trail:<anchor run id>`; stable for as long as the anchor stays.
  final String key;

  /// "Kastro loop": the anchor's street or place and loop / trail.
  final String name;
  final List<TrailRunFacts> runs;

  TrailRunFacts get anchor => runs.first;

  /// The fastest run by moving time (ties go to the earlier run).
  TrailRunFacts get best =>
      runs.reduce((a, b) => b.movingMs < a.movingMs ? b : a);
}

abstract final class Trails {
  /// Groups [runs] into trails. A run with no route, or one that matches no
  /// other, still forms a group of one (the verdict needs it); boards show
  /// only groups with two or more.
  static List<TrailGroup> group(Iterable<TrailRunFacts> runs) {
    final sorted = [
      for (final r in runs)
        if (r.route != null) r,
    ]..sort((a, b) => a.start.compareTo(b.start));
    final groups = <List<TrailRunFacts>>[];
    for (final r in sorted) {
      List<TrailRunFacts>? home;
      for (final g in groups) {
        if (RouteMatch.same(g.first.route!, r.route!)) {
          home = g;
          break;
        }
      }
      if (home == null) {
        groups.add([r]);
      } else {
        home.add(r);
      }
    }
    return [
      for (final g in groups)
        TrailGroup(key: 'trail:${g.first.id}', name: nameOf(g.first), runs: g),
    ];
  }

  /// The group [runId] belongs to, or null.
  static TrailGroup? groupOf(String runId, List<TrailGroup> groups) {
    for (final g in groups) {
      if (g.runs.any((r) => r.id == runId)) return g;
    }
    return null;
  }

  /// "Kastro loop" from where the first run started; editable later. Without
  /// a street or place it is dated, "Trail of 12 Sep".
  static String nameOf(TrailRunFacts anchor) {
    final base = anchor.street ?? anchor.place;
    final loop = anchor.route?.isLoop ?? false;
    if (base == null || base.trim().isEmpty) {
      return 'Trail of ${_dayMonth(anchor.start)}';
    }
    return '${base.trim()} ${loop ? 'loop' : 'trail'}';
  }
}

enum TrailBasis { sameTrail, effortPace, baseline, none }

/// How the headline reads; the screen picks the Aurora colour from it.
enum TrailTone { faster, slower, same, baseline, none }

/// A Trail run's result: judged against your earlier runs on the SAME trail
/// when there are any, else on grade-adjusted effort pace against your recent
/// trail runs. Never frozen into the sidecar; it is worked out from the index
/// each time it is shown, so it always agrees with the boards.
class TrailResult {
  const TrailResult({
    required this.basis,
    required this.tone,
    required this.headline,
    required this.subline,
    this.lines = const [],
    this.trailName,
    this.isTrailBest = false,
    this.comparedWith,
    this.deltaSec,
    this.runsOnTrail = 0,
  });

  final TrailBasis basis;
  final TrailTone tone;

  /// ALL CAPS, like every verdict word.
  final String headline;
  final String subline;

  /// More lines under the subline: climb, best on the trail, the why.
  final List<String> lines;
  final String? trailName;

  /// Fastest run on this trail so far (the cyan PB chip).
  final bool isTrailBest;

  /// "last", "best" or "median": what the headline was measured against.
  final String? comparedWith;

  /// Seconds (moving time) or s/km (effort pace), positive = faster.
  final double? deltaSec;

  /// How many runs this trail has, this one included (0 off a trail).
  final int runsOnTrail;
}

abstract final class TrailVerdict {
  /// Moving time on one trail: inside this, two runs are level.
  static double timeFloorSec(int refMs) => _max(15, refMs / 1000 * 0.015);

  /// Effort pace, s/km: inside this, two runs are level. Wider than the
  /// road floor because the grade model is an estimate.
  static double paceFloorSecPerKm(double refSecPerKm) =>
      _max(12, refSecPerKm * 0.025);

  /// Recent trail runs the effort-pace median is taken over.
  static const int medianSetSize = 6;

  static double _max(double a, double b) => a > b ? a : b;

  /// The verdict for [current] given every [others] Trail run (any date;
  /// only earlier ones are compared).
  static TrailResult of(
    TrailRunFacts current,
    Iterable<TrailRunFacts> others, {
    Units units = Units.km,
  }) {
    final earlier = [
      for (final r in others)
        if (r.id != current.id && r.start.isBefore(current.start)) r,
    ]..sort((a, b) => a.start.compareTo(b.start));

    if (current.route != null) {
      final groups = Trails.group([
        ...others.where((r) => r.id != current.id),
        current,
      ]);
      final g = Trails.groupOf(current.id, groups);
      final onTrail = [
        for (final r in g?.runs ?? const <TrailRunFacts>[])
          if (r.id != current.id && r.start.isBefore(current.start)) r,
      ];
      if (g != null && onTrail.isNotEmpty) {
        return _sameTrail(current, onTrail, g, units);
      }
    }
    return _effort(current, earlier, units);
  }

  static TrailResult _sameTrail(
    TrailRunFacts cur,
    List<TrailRunFacts> prior,
    TrailGroup group,
    Units units,
  ) {
    final last = prior.last;
    final best = prior.reduce((a, b) => b.movingMs < a.movingMs ? b : a);
    final deltaS = (last.movingMs - cur.movingMs) / 1000;
    final floor = timeFloorSec(last.movingMs);
    final when = _dayMonth(last.start);
    final TrailTone tone;
    final String headline;
    final String subline;
    if (deltaS >= floor) {
      tone = TrailTone.faster;
      headline = 'FASTER ON THIS TRAIL';
      subline =
          '${PaceFormat.mmss(deltaS)} quicker than $when, your last run here.';
    } else if (deltaS <= -floor) {
      tone = TrailTone.slower;
      headline = 'SLOWER ON THIS TRAIL';
      subline =
          '${PaceFormat.mmss(-deltaS)} slower than $when, your last run here.';
    } else {
      tone = TrailTone.same;
      headline = 'NO REAL CHANGE';
      final gap = deltaS.abs().round() == 0
          ? 'Same time as'
          : '${PaceFormat.mmss(deltaS.abs())} '
                '${deltaS > 0 ? 'quicker than' : 'slower than'}';
      subline =
          '$gap $when, your last run here. Inside the run-to-run noise '
          '(${PaceFormat.mmss(floor)}).';
    }

    final isBest = cur.movingMs < best.movingMs - floor * 1000;
    final lines = <String>[
      '${group.name}, your ${_ordinal(prior.length + 1)} run here.',
      'Moving time ${_clock(cur.movingMs)}, was ${_clock(last.movingMs)}.',
    ];
    final climb = _climbLine(cur, last, units);
    if (climb != null) lines.add(climb);
    if (isBest) {
      lines.add('Your best on this trail.');
    } else if (best.id == last.id) {
      lines.add('That $when run is also your best here.');
    } else {
      final off = (cur.movingMs - best.movingMs) / 1000;
      lines.add(
        'Your best here is ${_clock(best.movingMs)} (${_dayMonth(best.start)}). '
        '${off.abs() < floor ? 'You were level with it.' : 'You were ${PaceFormat.mmss(off)} off.'}',
      );
    }
    return TrailResult(
      basis: TrailBasis.sameTrail,
      tone: tone,
      headline: headline,
      subline: subline,
      lines: lines,
      trailName: group.name,
      isTrailBest: isBest,
      comparedWith: 'last',
      deltaSec: deltaS,
      runsOnTrail: prior.length + 1,
    );
  }

  static TrailResult _effort(
    TrailRunFacts cur,
    List<TrailRunFacts> earlier,
    Units units,
  ) {
    final gap = cur.gapSecPerKm;
    if (gap == null) {
      return const TrailResult(
        basis: TrailBasis.none,
        tone: TrailTone.none,
        headline: 'NO VERDICT',
        subline: 'No elevation on this run, so no effort pace.',
      );
    }
    final withGap = [
      for (final r in earlier)
        if (r.gapSecPerKm != null) r,
    ];
    final distKm = cur.distanceM / 1000;
    final climb = cur.climbM == null
        ? ''
        : ' with ${_height(cur.climbM!, units)} of climb';
    final dist = '${distKm.toStringAsFixed(1)} km';
    final now = PaceFormat.pace(gap, units);
    if (withGap.isEmpty) {
      return TrailResult(
        basis: TrailBasis.baseline,
        tone: TrailTone.baseline,
        headline: 'BASELINE SET',
        subline:
            'Effort pace $now over $dist$climb. Your next trail run gets a '
            'verdict.',
      );
    }
    final set = withGap.length > medianSetSize
        ? withGap.sublist(withGap.length - medianSetSize)
        : withGap;
    final median = _median([for (final r in set) r.gapSecPerKm!]);
    final delta = median - gap;
    final floor = paceFloorSecPerKm(median);
    final vs =
        '(${PaceFormat.paceBare(gap, units)} vs ${PaceFormat.pace(median, units)})';
    final TrailTone tone;
    final String headline;
    final String subline;
    if (delta >= floor) {
      tone = TrailTone.faster;
      headline = 'FASTER';
      subline =
          'Effort pace ${PaceFormat.delta(delta, units)} quicker than your '
          'recent trail runs $vs.';
    } else if (delta <= -floor) {
      tone = TrailTone.slower;
      headline = 'SLOWER';
      subline =
          'Effort pace ${PaceFormat.delta(delta, units)} slower than your '
          'recent trail runs $vs.';
    } else {
      tone = TrailTone.same;
      headline = 'NO REAL CHANGE';
      subline =
          'Effort pace within ${PaceFormat.delta(delta, units)} of your '
          'recent trail runs $vs. Inside the noise '
          '(${PaceFormat.delta(floor, units)}).';
    }
    return TrailResult(
      basis: TrailBasis.effortPace,
      tone: tone,
      headline: headline,
      subline: subline,
      lines: [
        'First time on this trail, so it is judged on effort pace: your pace '
            'with the hills evened out.',
        'Over $dist$climb.',
      ],
      comparedWith: 'median',
      deltaSec: delta,
    );
  }

  static double _median(List<double> v) {
    final s = [...v]..sort();
    final n = s.length;
    return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
  }

  /// "Climb 310 m, was 295 m." when both runs have one.
  static String? _climbLine(
    TrailRunFacts cur,
    TrailRunFacts last,
    Units units,
  ) {
    if (cur.climbM == null && last.climbM == null) return null;
    if (cur.climbM == null || last.climbM == null) {
      final one = cur.climbM ?? last.climbM!;
      return cur.climbM != null
          ? 'Climb ${_height(one, units)}.'
          : 'Climb was ${_height(one, units)}.';
    }
    return 'Climb ${_height(cur.climbM!, units)}, '
        'was ${_height(last.climbM!, units)}.';
  }

  static String _height(double m, Units units) =>
      units == Units.mi ? '${(m * 3.28084).round()} ft' : '${m.round()} m';

  static String _clock(int ms) {
    final total = (ms / 1000).round();
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
  }

  static String _ordinal(int n) {
    final tens = n % 100;
    if (tens >= 11 && tens <= 13) return '${n}th';
    return switch (n % 10) {
      1 => '${n}st',
      2 => '${n}nd',
      3 => '${n}rd',
      _ => '${n}th',
    };
  }
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _dayMonth(DateTime d) => '${d.day} ${_months[d.month - 1]}';

/// What a Trail run adds to the identity lanes (AEROBIC and LONG), never
/// SPEED, which comes from interval sessions only.
///
/// Why: a hilly run is a bigger effort than its pace says, and the lanes
/// otherwise ignore every trail run. Grade-adjusted pace (Minetti 2002, see
/// [Gap]) is the flat pace that would cost the same energy, so the run is
/// scored as if it had been run flat at that pace over the same distance: the
/// same Daniels-Gilbert VDOT as a road run, fed the effort time
/// (GAP x distance) instead of the clock time. The lanes keep the best
/// observation in a window, so a slow hilly 15K can lift LONG when its effort
/// time beats the road evidence, and can never pull a score down.
///
/// Fair only when:
/// - the run is at least [minDistanceM] (a short hilly burst proves little);
/// - the elevation is the barometer's (GPS-only altitude is too noisy for
///   the grade model; those runs just do not count here);
/// - it climbed at least [minClimbPerKm] m per km (on a flat run the GAP is
///   the pace, nothing to adjust, and it counts as a road run if run as
///   Free), and the adjustment is never worth more than [maxCredit] of the
///   clock time, so one wild grade estimate cannot mint a fantasy score.
///
/// This is the one place to tune the rule: change it here and Home, the
/// scores and the detail line all follow.
abstract final class TrailEffort {
  static const double minDistanceM = 3000;
  static const double minClimbPerKm = 10;
  static const double maxCredit = 0.25;

  /// The effort time in ms over [distanceM] for the lanes to score, or null
  /// when the run does not count.
  static int? effortMs({
    required double distanceM,
    required int movingMs,
    required double? gapSecPerKm,
    required double? climbM,
    required ElevSource? elevSrc,
  }) {
    if (gapSecPerKm == null || climbM == null) return null;
    if (elevSrc != ElevSource.baro) return null;
    if (distanceM < minDistanceM || movingMs <= 0) return null;
    if (climbM / (distanceM / 1000) < minClimbPerKm) return null;
    final effort = gapSecPerKm * distanceM / 1000 * 1000;
    final floor = movingMs * (1 - maxCredit);
    final ms = (effort < floor ? floor : effort).round();
    // Never a worse score than the clock gives: a descent-heavy run is not
    // marked down for being easy.
    return ms > movingMs ? movingMs : ms;
  }

  /// The wording on the score detail line.
  static const String note = 'Trail runs count using effort pace';

  /// What a LONG reading set by a trail run is called.
  static const String longSource = 'Trail run (effort pace)';
}
