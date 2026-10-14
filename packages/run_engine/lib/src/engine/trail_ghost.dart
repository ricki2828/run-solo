import 'dart:math' as math;

import '../model/run_file.dart';
import 'route_match.dart';

/// The in-run "known trail" ghost: recognising early in a run that it is on a
/// trail the runner has run before, and how far ahead or behind their best and
/// their last run they are at the same distance along that trail.
///
/// This file is the Dart twin of the recorder's Kotlin `TrailGhost` (core-jvm
/// `trail/TrailGhost.kt`): the same rules, held equal by shared vectors
/// (`test/fixtures/trail_ghost/vectors.json`, written by
/// `tool/gen_trail_ghost_vectors.dart`). The Dart side also BUILDS what the
/// recorder is handed ([TrailGhostBuilder]: the trail's geometry and the best
/// and last run as progress profiles) and replays old runs through the same
/// tracker for the audit. Pure Dart, no I/O.

/// One earlier run of a trail as a progress profile: [ms] is the moving time
/// since that run's start at each vertex of the [GhostTrail] geometry, -1
/// where the run did not reach (a shorter run).
class GhostProfile {
  const GhostProfile({
    required this.runId,
    required this.dateMs,
    required this.ms,
  });
  final String runId;
  final int dateMs;
  final List<int> ms;
}

/// A climb on a trail, read off its smoothed elevation profile: where it
/// starts and ends along the trail, what it gains and its average grade.
class GhostClimb {
  const GhostClimb({
    required this.startM,
    required this.endM,
    required this.gainM,
    required this.avgGradePct,
  });
  final double startM;
  final double endM;
  final double gainM;
  final double avgGradePct;
}

/// A trail the runner has run before, as the recorder takes it. [latLon] is
/// flat `[lat, lon, ...]`; a null [last] means the last run is the best;
/// [turnAlongM] is where an out-and-back trail turns round, else null.
///
/// [elevM] is the smoothed elevation (metres, 1 dp) at each vertex, null when
/// the trail's run had too little elevation; [elevSrc] is `baro` or `gps`;
/// [climbs] are empty unless the elevation is good enough to trust (barometer,
/// see [TrailGhostBuilder.elevation]).
class GhostTrail {
  GhostTrail({
    required this.id,
    required this.name,
    required this.latLon,
    required this.best,
    this.last,
    this.turnAlongM,
    this.elevM,
    this.elevSrc,
    this.climbs = const [],
  }) {
    final n = latLon.length ~/ 2;
    if (latLon.length.isOdd || n < 2 || n > maxPoints) {
      throw ArgumentError('a trail has 2..$maxPoints points, got $n');
    }
    if (best.ms.length != n || (last != null && last!.ms.length != n)) {
      throw ArgumentError('a profile needs one time per point');
    }
    if (elevM != null && elevM!.length != n) {
      throw ArgumentError('an elevation profile needs one value per point');
    }
  }

  /// The same caps as the Kotlin `TrailRef`: a bounded payload.
  static const int maxPoints = 400;
  static const int maxTrails = 6;

  final String id;
  final String name;
  final List<double> latLon;
  final GhostProfile best;
  final GhostProfile? last;
  final double? turnAlongM;
  final List<double>? elevM;
  final String? elevSrc;
  final List<GhostClimb> climbs;
}

/// What the tracker says after a fix once a trail is matched.
class GhostState {
  const GhostState({
    required this.trailId,
    required this.name,
    required this.alongM,
    required this.toGoM,
    required this.off,
    required this.aheadBestMs,
    required this.aheadLastMs,
    required this.lastIsBest,
    required this.bestDateMs,
    required this.lastDateMs,
    required this.toTurnM,
    required this.turnCue,
  });
  final String trailId;
  final String name;
  final double alongM;
  final double toGoM;
  final bool off;

  /// Positive = ahead; null while off, too early, or beyond where the run went.
  final int? aheadBestMs;
  final int? aheadLastMs;
  final bool lastIsBest;
  final int bestDateMs;
  final int lastDateMs;
  final double? toTurnM;
  final bool turnCue;
}

/// Tunables, the Kotlin `TrailGhost.Config` key for key.
class GhostConfig {
  const GhostConfig();
  // The line: a fix within this of the trail is on it (RouteMatch.coverTolM).
  final double onM = RouteMatch.coverTolM;
  final double offM = 40;
  final double backM = 25;
  final int offAfterMs = 10000;
  final int backAfterMs = 3000;
  final double maxAccuracyM = 30;
  final double backWindowM = 30;
  final double aheadBaseM = 250;
  final double maxSpeedMps = 7;
  final double tieM = 10;
  final int gapResetMs = 15000;
  // Start and finish of a loop sit this close (RouteMatch.endTolM).
  final double loopM = RouteMatch.endTolM;
  final double startZoneM = 200;
  final double engageWithinM = 600;
  final double confirmM = 300;
  final double minCover = RouteMatch.minCover;
  final double reportM = 100;
  final double endM = 20;
  final double endNearM = 60;
  final double endCrowM = 40;
  final double endAccuracyM = 20;
  final int endCueMs = 60000;
  final double endClearM = 60;
}

/// A turnaround event (the followed route's end rule: "End of route. Turn
/// around.").
class GhostTurnEvent {
  const GhostTurnEvent(this.t);
  final int t;
}

class GhostHit {
  const GhostHit(this.alongM, this.offM);
  final double alongM;
  final double offM;
}

/// The trail's geometry in local metres (equirectangular about the first
/// point), the Dart twin of the Kotlin `RoutePath` parts the ghost needs.
class GhostPath {
  GhostPath(List<double> latLon)
    : size = latLon.length ~/ 2,
      _lat0 = latLon[0],
      _lon0 = latLon[1],
      _kLon = mPerDeg * math.cos(latLon[0] * math.pi / 180) {
    _x = List.filled(size, 0);
    _y = List.filled(size, 0);
    cum = List.filled(size, 0);
    for (var i = 0; i < size; i++) {
      _x[i] = (latLon[2 * i + 1] - _lon0) * _kLon;
      _y[i] = (latLon[2 * i] - _lat0) * mPerDeg;
      if (i > 0) {
        cum[i] =
            cum[i - 1] +
            math.sqrt(_sq(_x[i] - _x[i - 1]) + _sq(_y[i] - _y[i - 1]));
      }
    }
    totalM = cum[size - 1];
  }

  static const double mPerDeg = 111320.0;
  static double _sq(double v) => v * v;

  final int size;
  final double _lat0;
  final double _lon0;
  final double _kLon;
  late final List<double> _x;
  late final List<double> _y;
  late final List<double> cum;
  late final double totalM;

  double toLocalX(double lon) => (lon - _lon0) * _kLon;
  double toLocalY(double lat) => (lat - _lat0) * mPerDeg;

  bool closesOnStart(double withinM) =>
      math.sqrt(_sq(_x[size - 1] - _x[0]) + _sq(_y[size - 1] - _y[0])) <=
      withinM;

  int _segmentAt(double alongM) {
    var lo = 0;
    var hi = size - 2;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (cum[mid] <= alongM) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  static double _clamp(double v, double lo, double hi) =>
      v < lo ? lo : (v > hi ? hi : v);

  (double, double) pointAt(double alongM) {
    final a = _clamp(alongM, 0, totalM);
    final i = _segmentAt(a);
    final segLen = cum[i + 1] - cum[i];
    final f = segLen > 0 ? (a - cum[i]) / segLen : 0.0;
    return (_x[i] + (_x[i + 1] - _x[i]) * f, _y[i] + (_y[i + 1] - _y[i]) * f);
  }

  /// [values] (one per vertex) interpolated at [alongM]; a negative
  /// neighbour (no value there) gives null.
  double? interpolate(double alongM, List<int> values) {
    final a = _clamp(alongM, 0, totalM);
    final i = _segmentAt(a);
    final v0 = values[i];
    final v1 = values[i + 1];
    if (v0 < 0 || v1 < 0) return null;
    final segLen = cum[i + 1] - cum[i];
    final f = segLen > 0 ? (a - cum[i]) / segLen : 0.0;
    return v0 + (v1 - v0) * f;
  }

  GhostHit _project(int i, double px, double py) {
    final dx = _x[i + 1] - _x[i];
    final dy = _y[i + 1] - _y[i];
    final len2 = dx * dx + dy * dy;
    final t = len2 == 0
        ? 0.0
        : _clamp(((px - _x[i]) * dx + (py - _y[i]) * dy) / len2, 0, 1);
    final off = math.sqrt(
      _sq(px - (_x[i] + t * dx)) + _sq(py - (_y[i] + t * dy)),
    );
    return GhostHit(cum[i] + t * math.sqrt(len2), off);
  }

  /// The nearest point among the stretch [fromAlongM]..[toAlongM]; an earlier
  /// separate pass over the same ground wins when about as near (progress
  /// follows the trail's order). Kotlin `RoutePath.nearest`.
  GhostHit? nearest(
    double px,
    double py,
    double fromAlongM,
    double toAlongM,
    double tieM,
  ) {
    if (toAlongM < fromAlongM) return null;
    final first = _segmentAt(_clamp(fromAlongM, 0, totalM));
    final last = _segmentAt(_clamp(toAlongM, 0, totalM));
    GhostHit? best;
    final hits = <GhostHit>[];
    for (var i = first; i <= last; i++) {
      final hit = _project(i, px, py);
      if (hit.alongM < fromAlongM - 1e-6 || hit.alongM > toAlongM + 1e-6) {
        continue;
      }
      hits.add(hit);
      if (best == null || hit.offM < best.offM) best = hit;
    }
    if (best == null) return null;
    GhostHit? earlier;
    for (final h in hits) {
      if (h.alongM < best.alongM - passGapM && h.offM <= best.offM + tieM) {
        if (earlier == null || h.alongM < earlier.alongM) earlier = h;
      }
    }
    return earlier ?? best;
  }

  /// Two points this far apart along the trail are different passes.
  static const double passGapM = 60;
}

class _Cand {
  _Cand(this.ref, this.cfg) : path = GhostPath(ref.latLon) {
    loopish = path.closesOnStart(cfg.loopM);
    final turn = ref.turnAlongM;
    if (turn != null && turn < path.totalM) apex = path.pointAt(turn);
  }

  final GhostTrail ref;
  final GhostPath path;
  final GhostConfig cfg;
  late final bool loopish;
  (double, double)? apex;
  bool dead = false;
  bool engaged = false;
  bool confirmed = false;
  bool off = false;
  double a0 = 0;
  double along = 0;
  int myT0 = 0;
  int n = 0;
  int onN = 0;
  double sumOff = 0;
  int? offSince;
  int? backSince;
  int? lastOnT;
  int? lastFixT;
  bool turnFired = false;
  int turnT = 0;
  double crowToApexM = double.maxFinite;

  double get meanOffM => onN == 0 ? double.maxFinite : sumOff / onN;

  void step(
    int t,
    double lat,
    double lon,
    double accuracyM,
    int activeMs,
    double runDistM,
  ) {
    final x = path.toLocalX(lon);
    final y = path.toLocalY(lat);
    final prev = lastFixT;
    lastFixT = t;
    final sinceFix = prev == null ? 0 : math.max(0, t - prev);
    if (sinceFix > cfg.gapResetMs) {
      offSince = null;
      backSince = null;
    }
    final onLimit = math.max(cfg.onM, accuracyM * 1.5);
    if (!engaged) {
      if (runDistM > cfg.engageWithinM) {
        dead = true;
        return;
      }
      final hit = loopish
          ? path.nearest(x, y, 0, path.totalM, cfg.tieM)
          : path.nearest(
              x,
              y,
              0,
              math.min(path.totalM, cfg.startZoneM),
              cfg.tieM,
            );
      if (hit != null && hit.offM <= onLimit) {
        engaged = true;
        a0 = hit.alongM;
        along = hit.alongM;
        myT0 = activeMs;
        lastOnT = t;
        n = 1;
        onN = 1;
        sumOff = hit.offM;
      }
      return;
    }
    final sinceOn = lastOnT == null ? 0 : math.max(0, t - lastOnT!);
    final away = math.max(sinceFix, (off || offSince != null) ? sinceOn : 0);
    final reach = cfg.aheadBaseM + cfg.maxSpeedMps * away / 1000.0;
    final hit = path.nearest(
      x,
      y,
      math.max(0, along - cfg.backWindowM),
      math.min(path.totalM, along + reach),
      cfg.tieM,
    );
    final dist = hit?.offM ?? double.maxFinite;
    n++;
    if (dist <= onLimit) {
      onN++;
      sumOff += dist;
    }
    final offLimit = math.max(cfg.offM, accuracyM * 1.5);
    final backLimit = math.max(cfg.backM, accuracyM);
    if (!off) {
      if (hit == null || dist > offLimit) {
        final since = offSince ?? (offSince = t);
        if (t - since >= cfg.offAfterMs) {
          if (confirmed) {
            off = true;
            offSince = null;
            backSince = null;
          } else {
            dead = true;
            return;
          }
        }
      } else {
        offSince = null;
        lastOnT = t;
        _advance(hit.alongM);
      }
    } else if (hit != null && dist <= backLimit) {
      final since = backSince ?? (backSince = t);
      if (t - since >= cfg.backAfterMs) {
        off = false;
        backSince = null;
        offSince = null;
        lastOnT = t;
        _advance(hit.alongM);
      }
    } else {
      backSince = null;
    }
    if (!confirmed && along - a0 >= cfg.confirmM && onN >= cfg.minCover * n) {
      confirmed = true;
    }
    final a = apex;
    if (a != null) {
      crowToApexM = math.sqrt(
        (x - a.$1) * (x - a.$1) + (y - a.$2) * (y - a.$2),
      );
    }
  }

  void _advance(double alongM) {
    if (alongM > along) along = alongM;
  }
}

/// The tracker. Feed it one accepted fix a second ([offer]); read [state].
class TrailGhostTracker {
  TrailGhostTracker(List<GhostTrail> refs, {this.config = const GhostConfig()})
    : _cands = [
        for (final r in refs.take(GhostTrail.maxTrails)) _Cand(r, config),
      ];

  final GhostConfig config;
  final List<_Cand> _cands;
  _Cand? _leader;

  /// The matched trail's state after the last fix; null until one is confirmed.
  GhostState? state;

  List<String> get candidateIds => [
    for (final c in _cands)
      if (!c.dead) c.ref.id,
  ];

  /// Takes one fix; returns the turnaround event when it fires (at most once
  /// per trail). A fix worse than [GhostConfig.maxAccuracyM] changes nothing.
  List<GhostTurnEvent> offer(
    int t,
    double lat,
    double lon,
    double accuracyM,
    int activeMs,
    double runDistM,
  ) {
    if (!lat.isFinite ||
        !lon.isFinite ||
        !accuracyM.isFinite ||
        accuracyM > config.maxAccuracyM) {
      return const [];
    }
    for (final c in _cands) {
      if (!c.dead) c.step(t, lat, lon, accuracyM, activeMs, runDistM);
    }
    final cur = _leader;
    if (cur == null || cur.off) {
      _Cand? next;
      for (final c in _cands) {
        if (c.confirmed && !c.dead && !c.off) {
          if (next == null || c.meanOffM < next.meanOffM) next = c;
        }
      }
      if (next != null) _leader = next;
    }
    final lead = _leader;
    if (lead == null) {
      state = null;
      return const [];
    }
    final events = <GhostTurnEvent>[];
    final turn = lead.ref.turnAlongM;
    if (turn != null &&
        lead.apex != null &&
        !lead.off &&
        !lead.turnFired &&
        lead.a0 < turn - config.endNearM &&
        accuracyM <= config.endAccuracyM) {
      final toApex = turn - lead.along;
      if (toApex <= config.endM ||
          (toApex <= config.endNearM &&
              lead.crowToApexM <= math.max(config.endCrowM, accuracyM * 1.5))) {
        lead.turnFired = true;
        lead.turnT = t;
        events.add(GhostTurnEvent(t));
      }
    }
    state = _stateOf(lead, t, activeMs);
    return events;
  }

  GhostState _stateOf(_Cand c, int t, int activeMs) {
    final ref = c.ref;
    final reported = !c.off && c.along - c.a0 >= config.reportM;
    int? ahead(GhostProfile p) {
      if (!reported) return null;
      final at = c.path.interpolate(c.along, p.ms);
      final from = c.path.interpolate(c.a0, p.ms);
      if (at == null || from == null) return null;
      return _roundHalfUp((at - from) - (activeMs - c.myT0));
    }

    final last = ref.last ?? ref.best;
    final turn = ref.turnAlongM;
    return GhostState(
      trailId: ref.id,
      name: ref.name,
      alongM: c.along,
      toGoM: math.max(0, c.path.totalM - c.along),
      off: c.off,
      aheadBestMs: ahead(ref.best),
      aheadLastMs: ahead(last),
      lastIsBest: ref.last == null,
      bestDateMs: ref.best.dateMs,
      lastDateMs: last.dateMs,
      toTurnM: (turn != null && !c.turnFired && c.along < turn)
          ? turn - c.along
          : null,
      turnCue:
          c.turnFired &&
          t - c.turnT < config.endCueMs &&
          c.crowToApexM <= config.endClearM,
    );
  }

  /// Kotlin's `roundToLong` (half up, towards +infinity).
  static int _roundHalfUp(double v) => (v + 0.5).floor();
}

/// Builds what the recorder is handed from the runs of one trail group.
abstract final class TrailGhostBuilder {
  /// Vertices are at least this far apart (and at most 400 of them in all).
  static const double minStepM = 25;

  /// Simplification of the raw track before it is resampled (jitter out).
  static const double simplifyM = 5;

  /// A vertex counts as reached by a run when it got within this of it.
  static const double reachSlackM = 20;

  /// The trail for [id]/[name] from the group's [best] and [last] runs (the
  /// same run is fine). The geometry is the longer of the two. Null when
  /// neither has a usable track.
  static GhostTrail? build({
    required String id,
    required String name,
    required RunFile best,
    required RunFile last,
  }) {
    final geomRun = last.distanceM >= best.distanceM ? last : best;
    final geo = geometry(geomRun);
    if (geo == null) return null;
    final path = GhostPath(geo);
    final bestMs = profile(path, best);
    if (bestMs == null) return null;
    final same = best.id == last.id;
    final lastMs = same ? null : profile(path, last);
    final elev = elevation(path, geomRun);
    return GhostTrail(
      id: id,
      name: name,
      latLon: geo,
      best: GhostProfile(
        runId: best.id,
        dateMs: best.start.millisecondsSinceEpoch,
        ms: bestMs,
      ),
      last: lastMs == null
          ? null
          : GhostProfile(
              runId: last.id,
              dateMs: last.start.millisecondsSinceEpoch,
              ms: lastMs,
            ),
      turnAlongM: turnaround(geo),
      elevM: elev?.elevM,
      elevSrc: elev?.src,
      climbs: elev?.climbs ?? const [],
    );
  }

  static List<(double, double)> _fixes(RunFile run) => [
    for (final s in run.samples)
      if (s.lat != null &&
          s.lon != null &&
          (s.accM ?? 0) <= RouteSignature.maxAccuracyM)
        (s.lat!, s.lon!),
  ];

  /// The simplified, resampled track as flat `[lat, lon, ...]`, 6 dp; null
  /// without a usable track.
  static List<double>? geometry(RunFile run) {
    final fixes = _fixes(run);
    if (fixes.length < 2) return null;
    final lat0 = fixes.first.$1, lon0 = fixes.first.$2;
    final kx = math.cos(lat0 * math.pi / 180) * GhostPath.mPerDeg;
    final xy = [
      for (final f in fixes)
        ((f.$2 - lon0) * kx, (f.$1 - lat0) * GhostPath.mPerDeg),
    ];
    final keep = _simplify(xy, simplifyM);
    final pts = [for (final i in keep) xy[i]];
    var len = 0.0;
    for (var i = 1; i < pts.length; i++) {
      len += _d(pts[i - 1], pts[i]);
    }
    if (len < RouteSignature.minLengthM) return null;
    final step = math.max(minStepM, len / (GhostTrail.maxPoints - 1));
    final n = (len / step).ceil();
    final out = <double>[];
    var seg = 0;
    var walked = 0.0;
    for (var k = 0; k <= n; k++) {
      final target = len * k / n;
      while (seg + 1 < pts.length - 1 &&
          walked + _d(pts[seg], pts[seg + 1]) < target) {
        walked += _d(pts[seg], pts[seg + 1]);
        seg++;
      }
      final l = _d(pts[seg], pts[seg + 1]);
      final f = l == 0 ? 0.0 : ((target - walked) / l).clamp(0.0, 1.0);
      final x = pts[seg].$1 + f * (pts[seg + 1].$1 - pts[seg].$1);
      final y = pts[seg].$2 + f * (pts[seg + 1].$2 - pts[seg].$2);
      out
        ..add(_dp6(lat0 + y / GhostPath.mPerDeg))
        ..add(_dp6(lon0 + x / kx));
    }
    return out;
  }

  static double _dp6(double v) => (v * 1e6).round() / 1e6;

  static double _d((double, double) a, (double, double) b) =>
      math.sqrt((a.$1 - b.$1) * (a.$1 - b.$1) + (a.$2 - b.$2) * (a.$2 - b.$2));

  static List<int> _simplify(List<(double, double)> p, double eps) {
    final keep = <int>{0, p.length - 1};
    final stack = <(int, int)>[(0, p.length - 1)];
    while (stack.isNotEmpty) {
      final (a, b) = stack.removeLast();
      var far = -1;
      var farD = eps;
      for (var i = a + 1; i < b; i++) {
        final d = _segDist(p[i], p[a], p[b]);
        if (d > farD) {
          farD = d;
          far = i;
        }
      }
      if (far >= 0) {
        keep.add(far);
        stack
          ..add((a, far))
          ..add((far, b));
      }
    }
    return keep.toList()..sort();
  }

  static double _segDist(
    (double, double) p,
    (double, double) a,
    (double, double) b,
  ) {
    final dx = b.$1 - a.$1, dy = b.$2 - a.$2;
    final l2 = dx * dx + dy * dy;
    if (l2 == 0) return _d(p, a);
    final t = (((p.$1 - a.$1) * dx + (p.$2 - a.$2) * dy) / l2).clamp(0.0, 1.0);
    return _d(p, (a.$1 + t * dx, a.$2 + t * dy));
  }

  /// Moving ms at a sample time: elapsed minus pauses and recording gaps.
  static int Function(int) _movingClock(RunFile run) {
    final spans = <(int, int)>[
      for (final s in [...run.pauses, ...run.gaps]) (s.t0Ms, s.t1Ms),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    final merged = <(int, int)>[];
    for (final s in spans) {
      if (merged.isNotEmpty && s.$1 <= merged.last.$2) {
        if (s.$2 > merged.last.$2) {
          merged[merged.length - 1] = (merged.last.$1, s.$2);
        }
      } else {
        merged.add(s);
      }
    }
    return (int t) {
      var lost = 0;
      for (final m in merged) {
        if (m.$1 >= t) break;
        lost += math.min(m.$2, t) - m.$1;
      }
      return math.max(0, t - lost);
    };
  }

  /// [run] projected onto [path] with the forward-only rule the recorder
  /// uses: strictly increasing distance along the trail, with the run's moving
  /// time and fused elevation (null when the sample has none) at each point.
  static ({List<double> along, List<int> time, List<double?> elev}) _track(
    GhostPath path,
    RunFile run,
  ) {
    final clock = _movingClock(run);
    const cfg = GhostConfig();
    final along = <double>[];
    final time = <int>[];
    final elev = <double?>[];
    var cur = 0.0;
    var started = false;
    int? lastT;
    for (final s in run.samples) {
      if (s.lat == null || s.lon == null) continue;
      if ((s.accM ?? 0) > cfg.maxAccuracyM) continue;
      final x = path.toLocalX(s.lon!), y = path.toLocalY(s.lat!);
      GhostHit? hit;
      if (!started) {
        hit = path.nearest(x, y, 0, path.totalM, cfg.tieM);
        if (hit == null || hit.offM > cfg.onM) continue;
        started = true;
      } else {
        final away = lastT == null ? 0 : math.max(0, s.tMs - lastT);
        final reach = cfg.aheadBaseM + cfg.maxSpeedMps * away / 1000.0;
        hit = path.nearest(
          x,
          y,
          math.max(0, cur - cfg.backWindowM),
          math.min(path.totalM, cur + reach),
          cfg.tieM,
        );
        if (hit == null || hit.offM > cfg.offM) continue;
      }
      lastT = s.tMs;
      cur = math.max(cur, hit.alongM);
      if (along.isNotEmpty && cur <= along.last) continue;
      along.add(cur);
      time.add(clock(s.tMs));
      elev.add(s.elevM);
    }
    return (along: along, time: time, elev: elev);
  }

  /// [run]'s moving time at each vertex of [path], -1 where it did not reach.
  /// The run is projected onto the trail with the same forward-only rule the
  /// recorder uses, so "time at distance along the trail" means the same
  /// thing to both. Null when the run never gets onto the trail.
  static List<int>? profile(GhostPath path, RunFile run) {
    final tr = _track(path, run);
    final along = tr.along, time = tr.time;
    if (along.length < 2) return null;
    final out = List<int>.filled(path.size, -1);
    var j = 0;
    for (var i = 0; i < path.size; i++) {
      final c = path.cum[i];
      if (c < along.first - reachSlackM || c > along.last + reachSlackM) {
        continue;
      }
      if (c <= along.first) {
        out[i] = time.first;
        continue;
      }
      if (c >= along.last) {
        out[i] = time.last;
        continue;
      }
      while (j + 1 < along.length - 1 && along[j + 1] < c) {
        j++;
      }
      final span = along[j + 1] - along[j];
      final f = span <= 0 ? 0.0 : (c - along[j]) / span;
      out[i] = (time[j] + (time[j + 1] - time[j]) * f).round();
    }
    // Monotone: a vertex is never reached before the one behind it.
    var prev = -1;
    for (var i = 0; i < out.length; i++) {
      if (out[i] < 0) continue;
      if (out[i] < prev) out[i] = prev;
      prev = out[i];
    }
    return out;
  }

  /// Elevation is smoothed over at least this much trail (a moving average).
  static const double elevSmoothM = 60;

  /// At least this share of the trail must lie within [elevGapM] of an
  /// elevation sample, else there is no profile at all.
  static const double elevMinCover = 0.7;
  static const double elevGapM = 100;

  /// A climb: the smoothed profile rises at least [climbMinGainM] over at
  /// least [climbMinLenM], and a dip of less than [climbTurnM] does not end it.
  static const double climbMinGainM = 15;
  static const double climbMinLenM = 100;
  static const double climbTurnM = 5;
  static const double climbEdgeM = 1;
  static const int maxClimbs = 12;

  /// The smoothed elevation at each vertex of [path] and its climbs, read
  /// from [run]'s fused elevation. Null when too few samples carry elevation.
  /// Climbs are left out (empty) unless the run's elevation came from the
  /// barometer: GPS altitude alone is too noisy to name a climb, and a wrong
  /// "steep climb ahead" is worse than none.
  static ({List<double> elevM, String src, List<GhostClimb> climbs})? elevation(
    GhostPath path,
    RunFile run,
  ) {
    final src = run.elevSrc;
    if (src == null) return null;
    final tr = _track(path, run);
    final pa = <double>[], pe = <double>[];
    for (var i = 0; i < tr.along.length; i++) {
      final e = tr.elev[i];
      if (e != null && e.isFinite) {
        pa.add(tr.along[i]);
        pe.add(e);
      }
    }
    if (pa.length < 2) return null;
    // Raw elevation at each vertex, interpolated between samples; a vertex far
    // from any sample has none.
    final raw = List<double?>.filled(path.size, null);
    var covered = 0;
    var j = 0;
    for (var i = 0; i < path.size; i++) {
      final c = path.cum[i];
      if (c < pa.first - elevGapM || c > pa.last + elevGapM) continue;
      double v;
      if (c <= pa.first) {
        v = pe.first;
      } else if (c >= pa.last) {
        v = pe.last;
      } else {
        while (j + 1 < pa.length - 1 && pa[j + 1] < c) {
          j++;
        }
        final span = pa[j + 1] - pa[j];
        if (span > 2 * elevGapM) continue;
        final f = span <= 0 ? 0.0 : (c - pa[j]) / span;
        v = pe[j] + (pe[j + 1] - pe[j]) * f;
      }
      raw[i] = v;
      covered++;
    }
    if (covered < elevMinCover * path.size) return null;
    // Fill the ends the run did not reach with the nearest value.
    double? carry;
    for (var i = 0; i < path.size; i++) {
      if (raw[i] != null) {
        carry = raw[i];
      } else if (carry != null) {
        raw[i] = carry;
      }
    }
    carry = null;
    for (var i = path.size - 1; i >= 0; i--) {
      if (raw[i] != null) {
        carry = raw[i];
      } else if (carry != null) {
        raw[i] = carry;
      }
    }
    // Moving average over +-elevSmoothM/2 of trail.
    final sm = List<double>.filled(path.size, 0);
    for (var i = 0; i < path.size; i++) {
      var sum = 0.0, n = 0;
      for (
        var k = i;
        k >= 0 && path.cum[i] - path.cum[k] <= elevSmoothM / 2;
        k--
      ) {
        sum += raw[k]!;
        n++;
      }
      for (
        var k = i + 1;
        k < path.size && path.cum[k] - path.cum[i] <= elevSmoothM / 2;
        k++
      ) {
        sum += raw[k]!;
        n++;
      }
      sm[i] = (sum / n * 10).round() / 10;
    }
    final climbs = src == ElevSource.baro
        ? _climbs(path.cum, sm)
        : <GhostClimb>[];
    return (elevM: sm, src: src.name, climbs: climbs);
  }

  /// Rises of the smoothed profile: from each trough to the next peak, a dip
  /// of under [climbTurnM] not ending the rise. The ends are pulled in to
  /// where the profile first and last comes within [climbEdgeM] of the trough
  /// and the peak, so a wobbling flat start or top is not counted as climb.
  static List<GhostClimb> _climbs(List<double> cum, List<double> e) {
    final out = <GhostClimb>[];
    var lo = 0; // lowest vertex of the current leg
    var hi = 0; // highest vertex since lo
    void close() {
      if (e[hi] - e[lo] < climbMinGainM) return;
      var a = lo, b = hi;
      while (a < b && e[a + 1] <= e[lo] + climbEdgeM) {
        a++;
      }
      while (b > a && e[b - 1] >= e[hi] - climbEdgeM) {
        b--;
      }
      final gain = e[b] - e[a];
      final len = cum[b] - cum[a];
      if (gain >= climbMinGainM && len >= climbMinLenM) {
        out.add(
          GhostClimb(
            startM: _r1(cum[a]),
            endM: _r1(cum[b]),
            gainM: _r1(gain),
            avgGradePct: _r1(gain / len * 100),
          ),
        );
      }
    }

    for (var i = 1; i < e.length; i++) {
      if (e[hi] - e[i] >= climbTurnM) {
        close();
        lo = i;
        hi = i;
      } else if (e[i] > e[hi]) {
        hi = i;
      } else if (e[i] < e[lo] && hi - lo >= 0 && e[hi] - e[lo] < climbTurnM) {
        lo = i;
        hi = i;
      }
    }
    close();
    if (out.length > maxClimbs) {
      out.sort((a, b) => b.gainM.compareTo(a.gainM));
      out.removeRange(maxClimbs, out.length);
      out.sort((a, b) => a.startM.compareTo(b.startM));
    }
    return out;
  }

  static double _r1(double v) => (v * 10).round() / 10;

  /// Where the trail turns round when it is an out-and-back: the vertex
  /// furthest from the start as the crow flies, in the middle half of the
  /// trail, with the way back lying on the way out (at least
  /// [RouteMatch.minCover] of the return within [RouteMatch.coverTolM] of the
  /// outward leg). A loop or a point-to-point trail has none (null).
  static double? turnaround(List<double> latLon) {
    final path = GhostPath(latLon);
    if (path.totalM < 300) return null;
    var apexI = 0;
    var apexD = -1.0;
    for (var i = 0; i < path.size; i++) {
      final p = path.pointAt(path.cum[i]);
      final d = p.$1 * p.$1 + p.$2 * p.$2;
      if (d > apexD) {
        apexD = d;
        apexI = i;
      }
    }
    final along = path.cum[apexI];
    if (along < path.totalM * 0.25 || along > path.totalM * 0.75) return null;
    // The outward leg is 0..along; sample the return every 10 m.
    var hit = 0, n = 0;
    for (var s = along; s <= path.totalM; s += 10) {
      final p = path.pointAt(s);
      n++;
      final h = path.nearest(p.$1, p.$2, 0, along, 0);
      if (h != null && h.offM <= RouteMatch.coverTolM) hit++;
    }
    if (n == 0 || hit / n < RouteMatch.minCover) return null;
    return along;
  }
}
