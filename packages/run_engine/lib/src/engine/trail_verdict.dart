import '../model/run_file.dart';
import 'format.dart';
import 'true_pace.dart';
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
    this.gradeFactor,
    this.heatFactor = 1,
    this.route,
    this.place,
    this.street,
  });

  final String id;
  final DateTime start;
  final int movingMs;
  final double distanceM;
  final double? climbM;

  /// The whole run's hills factor ([TruePace]; 1 for GPS-only elevation);
  /// null without elevation, which leaves a first-time trail run with no
  /// verdict.
  final double? gradeFactor;

  /// The whole run's heat factor (1 without weather or on a cool day).
  final double heatFactor;
  final RouteSignature? route;
  final String? place;
  final String? street;

  TruePaceFactors get factors =>
      TruePaceFactors(grade: gradeFactor ?? 1, heat: heatFactor);

  /// The actual moving pace, s/km.
  double get rawPaceSecPerKm => movingMs / distanceM;

  /// TRUE PACE, s/km (flat ground, cool day); null without elevation.
  double? get truePaceSecPerKm =>
      gradeFactor == null ? null : factors.apply(rawPaceSecPerKm);

  /// Moving time with the heat taken out, ms. The same trail has the same
  /// hills every time, so a same-trail comparison only needs the heat.
  int get heatAdjustedMovingMs => (movingMs * heatFactor).round();
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

  /// The fastest run by heat-adjusted moving time (ties go to the earlier
  /// run).
  TrailRunFacts get best => runs.reduce(
    (a, b) => b.heatAdjustedMovingMs < a.heatAdjustedMovingMs ? b : a,
  );
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
/// when there are any (heat-adjusted moving time: the hills are identical),
/// else on True Pace against your recent trail runs. Never frozen into the sidecar; it is worked out from the index
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

  /// Seconds (heat-adjusted moving time) or s/km (true pace), positive =
  /// faster.
  final double? deltaSec;

  /// How many runs this trail has, this one included (0 off a trail).
  final int runsOnTrail;
}

abstract final class TrailVerdict {
  /// Heat-adjusted moving time on one trail: inside this, two runs are
  /// level.
  static double timeFloorSec(int refMs) => _max(15, refMs / 1000 * 0.015);

  /// True pace, s/km: inside this, two runs are level. Wider than the road
  /// floor because the grade model is an estimate.
  static double paceFloorSecPerKm(double refSecPerKm) =>
      _max(12, refSecPerKm * 0.025);

  /// Recent trail runs the true-pace median is taken over.
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
    final best = prior.reduce(
      (a, b) => b.heatAdjustedMovingMs < a.heatAdjustedMovingMs ? b : a,
    );
    final deltaS =
        (last.heatAdjustedMovingMs - cur.heatAdjustedMovingMs) / 1000;
    final floor = timeFloorSec(last.heatAdjustedMovingMs);
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

    final isBest =
        cur.heatAdjustedMovingMs < best.heatAdjustedMovingMs - floor * 1000;
    final lines = <String>[
      '${group.name}, your ${_ordinal(prior.length + 1)} run here.',
      'Moving time ${_clock(cur.movingMs)}, was ${_clock(last.movingMs)}.',
    ];
    final heat = _heatLine(cur, last);
    if (heat != null) lines.add(heat);
    final climb = _climbLine(cur, last, units);
    if (climb != null) lines.add(climb);
    if (isBest) {
      lines.add('Your best on this trail.');
    } else if (best.id == last.id) {
      lines.add('That $when run is also your best here.');
    } else {
      final off = (cur.heatAdjustedMovingMs - best.heatAdjustedMovingMs) / 1000;
      lines.add(
        'Your best here is ${_clock(best.heatAdjustedMovingMs)} '
        '(${_dayMonth(best.start)}${_cool(best) ? '' : ', cool-day time'}). '
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

  /// Neither run was run in heat worth naming, so no heat line is needed.
  static bool _cool(TrailRunFacts r) => !r.factors.hot;

  /// "In cool conditions that is 1:01:12, was 1:02:40." when either run was
  /// hot, so the heat-adjusted comparison is never a surprise.
  static String? _heatLine(TrailRunFacts cur, TrailRunFacts last) {
    if (_cool(cur) && _cool(last)) return null;
    return 'In cool conditions that is ${_clock(cur.heatAdjustedMovingMs)}, '
        'was ${_clock(last.heatAdjustedMovingMs)}.';
  }

  static TrailResult _effort(
    TrailRunFacts cur,
    List<TrailRunFacts> earlier,
    Units units,
  ) {
    final truePace = cur.truePaceSecPerKm;
    if (truePace == null) {
      return const TrailResult(
        basis: TrailBasis.none,
        tone: TrailTone.none,
        headline: 'NO VERDICT',
        subline: 'No elevation on this run, so no true pace.',
      );
    }
    final withPace = [
      for (final r in earlier)
        if (r.truePaceSecPerKm != null) r,
    ];
    final distKm = cur.distanceM / 1000;
    final climb = cur.climbM == null
        ? ''
        : ' with ${_height(cur.climbM!, units)} of climb';
    final dist = '${distKm.toStringAsFixed(1)} km';
    final now = TruePaceText.headline(cur.rawPaceSecPerKm, cur.factors, units);
    if (withPace.isEmpty) {
      return TrailResult(
        basis: TrailBasis.baseline,
        tone: TrailTone.baseline,
        headline: 'BASELINE SET',
        subline: '$now over $dist$climb. Your next trail run gets a verdict.',
      );
    }
    final set = withPace.length > medianSetSize
        ? withPace.sublist(withPace.length - medianSetSize)
        : withPace;
    final median = _median([for (final r in set) r.truePaceSecPerKm!]);
    final delta = median - truePace;
    final floor = paceFloorSecPerKm(median);
    final vs =
        '(${PaceFormat.paceBare(truePace, units)} vs ${PaceFormat.pace(median, units)})';
    final TrailTone tone;
    final String headline;
    final String subline;
    if (delta >= floor) {
      tone = TrailTone.faster;
      headline = 'FASTER';
      subline =
          'True pace ${PaceFormat.delta(delta, units)} quicker than your '
          'recent trail runs $vs.';
    } else if (delta <= -floor) {
      tone = TrailTone.slower;
      headline = 'SLOWER';
      subline =
          'True pace ${PaceFormat.delta(delta, units)} slower than your '
          'recent trail runs $vs.';
    } else {
      tone = TrailTone.same;
      headline = 'NO REAL CHANGE';
      subline =
          'True pace within ${PaceFormat.delta(delta, units)} of your '
          'recent trail runs $vs. Inside the noise '
          '(${PaceFormat.delta(floor, units)}).';
    }
    return TrailResult(
      basis: TrailBasis.effortPace,
      tone: tone,
      headline: headline,
      subline: subline,
      lines: [
        'First time on this trail, so it is judged on true pace: your pace '
            'with the hills and the heat taken out.',
        '$now over $dist$climb.',
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
/// otherwise ignore every trail run. The run is scored at its TRUE PACE
/// ([TruePace]: hills per Minetti 2002, heat per the §18.5 table) held over
/// the same distance: the same Daniels-Gilbert VDOT as a road run, fed the
/// flat, cool-day time instead of the clock time. This replaces the old
/// separate "effort pace" credit, and its caps still apply through the one
/// model:
/// - at least [minDistanceM] (a short hilly burst proves little);
/// - it has barometer elevation (GPS-only altitude is too noisy for the
///   grade model, so such a run does not count here, as before);
/// - hills and heat together move the time by at most 20% for scoring
///   ([TruePace.minScoringFactor]; the display clamps are wider), so one wild
///   grade estimate cannot mint a fantasy score. The old "never worse than the clock" rule is gone: True Pace is
///   a fair pace, a long net descent reads slower, and the lanes keep the
///   best reading in a window, so an easy day never lowers a score.
///
/// This is the one place to tune the rule: change it here and Home, the
/// scores and the detail line all follow.
abstract final class TrailScore {
  static const double minDistanceM = 3000;

  /// The moving time a trail run is scored from (the lanes apply True Pace
  /// to it), or null when the run is too short or has no barometer.
  static int? movingMs({
    required double distanceM,
    required int movingMs,
    required ElevSource? elevSrc,
  }) => elevSrc != ElevSource.baro || distanceM < minDistanceM || movingMs <= 0
      ? null
      : movingMs;

  /// The wording on the score detail line.
  static const String note = 'Trail runs count at true pace';

  /// What a LONG reading set by a trail run is called.
  static const String longSource = 'Trail run (true pace)';
}
