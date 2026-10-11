/// RunBundle -> the body the app POSTs to the companion's /v1/runs.
///
/// A pure-Dart port of `companionSummary` (lib/state/companion.dart) and the
/// pieces it reads, so the history can be replayed through the live coach
/// without a phone. Keep it in step with that function: the key set, the
/// rounding (`r1`) and which keys are left out when null all match it.
///
/// What a bundle cannot tell us (settings and phone-side lookups):
/// - HR zones: the runner's zone method and max HR live in app settings, so
///   they are options here ([CompanionFactsOptions]); the default is the
///   app's own fallback, percent of a 190 bpm max.
/// - `locality`: only present when the phone's geocoder had answered and the
///   sidecar carries it.
/// - The verdict is recomputed by the engine over the runs given, oldest
///   first, as the app's history analyser does; the app's observed-max-HR
///   state is not in a bundle, so a profile max HR is an option as well.
library;

import 'package:run_engine/run_engine.dart';

class CompanionFactsOptions {
  const CompanionFactsOptions({
    this.maxHr,
    this.age,
    this.restingHr,
    this.names = EventNames.generic,
  });

  /// Typed max HR (Settings). Null: the app's fallback of 190.
  final int? maxHr;
  final int? age;

  /// Set to use heart-rate-reserve zones, as Settings > Heart rate zones does.
  final int? restingHr;
  final EventNames names;

  UserProfile get profile => UserProfile(maxHr: maxHr, age: age);

  HrZones get zones {
    final max = maxHr ?? (age != null ? 220 - age! : 190);
    final rest = restingHr;
    if (rest != null && rest < max) return HrZones.reserve(rest, max);
    return HrZones.percentMax(max);
  }
}

/// Fields of the app payload that this converter cannot derive for a run.
/// The companion's RunIn accepts all of them. `plan_kind`, `plan_target_m`,
/// `plan_week`, `plan_weeks` and `plan_next` come from the phone's stored
/// 4-week plan (`companionPlanFacts`), which is not in a bundle, so they are
/// absent here. `plan_weeks_to_race` the app never sends: it has no race date.
const List<String> kNotSentByTheApp = [
  'scores_delta',
  'route_id',
  'load_state',
  'pb',
  'plan_kind',
  'plan_target_m',
  'plan_weeks_to_race',
  'plan_week',
  'plan_weeks',
  'plan_next',
  'area_lat',
  'area_lon',
];

double _r1(double v) => (v * 10).roundToDouble() / 10;
double _dp1(double v) => (v * 10).round() / 10;

/// `companionZoneId` in the app.
String? zoneIdFor(String? zoneId, int? offsetMin) {
  if (zoneId != null && zoneId.isNotEmpty) return zoneId;
  if (offsetMin == null || offsetMin % 60 != 0) return null;
  final h = offsetMin ~/ 60;
  if (h == 0) return 'Etc/UTC';
  if (h < -12 || h > 14) return null;
  return h > 0 ? 'Etc/GMT-$h' : 'Etc/GMT+${-h}';
}

List<Span> _merged(List<Span> spans) {
  final sorted = [...spans]..sort((a, b) => a.t0Ms.compareTo(b.t0Ms));
  final out = <Span>[];
  for (final s in sorted) {
    if (out.isNotEmpty && s.t0Ms <= out.last.t1Ms) {
      if (s.t1Ms > out.last.t1Ms) {
        out[out.length - 1] = Span(out.last.t0Ms, s.t1Ms);
      }
    } else {
      out.add(Span(s.t0Ms, s.t1Ms));
    }
  }
  return out;
}

int _pausedWithin(List<Span> merged, int aMs, int bMs) {
  var ms = 0;
  for (final p in merged) {
    if (p.t0Ms >= bMs) break;
    if (p.t1Ms <= aMs) continue;
    ms += (p.t1Ms < bMs ? p.t1Ms : bMs) - (p.t0Ms > aMs ? p.t0Ms : aMs);
  }
  return ms;
}

/// `zoneSecondsOf` in lib/state/zone_histogram.dart: moving seconds per HR
/// zone, index 0 = no heart rate.
List<double> zoneSecondsOf(RunFile run, HrZones zones) {
  final out = List<double>.filled(6, 0);
  final samples = run.samples;
  final pauses = _merged(run.pauses);
  for (var i = 0; i < samples.length; i++) {
    final s = samples[i];
    final dtMs = i + 1 < samples.length
        ? (samples[i + 1].tMs - s.tMs).clamp(0, 5000)
        : 1000;
    final dt = (dtMs - _pausedWithin(pauses, s.tMs, s.tMs + dtMs)) / 1000;
    if (dt <= 0) continue;
    final hr = s.hr;
    if (hr == null) {
      out[0] += dt;
      continue;
    }
    out[zones.zoneOf(hr)] += dt;
  }
  return out;
}

/// One payload per bundle, oldest first. A run the app would have held back
/// (no resolvable time zone) is returned as null in the list, never invented.
List<Map<String, Object?>?> companionFactsFor(
  List<RunBundle> bundles, {
  CompanionFactsOptions options = const CompanionFactsOptions(),
}) {
  final ordered = [...bundles]
    ..sort((a, b) => a.run.start.compareTo(b.run.start));
  final engine = RunEngine(names: options.names);
  final priors = <PriorRun>[];
  final out = <Map<String, Object?>?>[];
  final zones = options.zones;
  for (final b in ordered) {
    final run = b.run;
    final sidecar = b.sidecar ?? RunSidecar(runId: run.id);
    RunAnalysis? a;
    try {
      a = engine.analyze(
        run,
        sidecar: sidecar,
        priors: List.of(priors),
        profile: options.profile,
        now: run.end.toUtc(),
      );
      final p = a.asPrior(run.start);
      if (p != null) priors.add(p);
    } catch (_) {
      a = null; // the app skips a failed analysis too: no verdict, no true pace
    }
    final mode = sidecar.runTypeOverride ?? a?.mode ?? run.mode;
    final local = RunZone.resolve(
      run,
      zoneId: sidecar.zoneId,
      stampedOffsetMin: sidecar.utcOffsetMin,
    );
    final offset = local?.offsetMin;
    final zone = zoneIdFor(local?.zoneId ?? sidecar.zoneId, offset);
    if (offset == null || zone == null) {
      out.add(null);
      continue;
    }
    // Only a 4x4 (Intervals mode) carries a verdict word, as in _summaryOf.
    final headline = mode == RunMode.intervals
        ? a?.verdict?.headline.name
        : null;
    Map<String, double>? zoneMin;
    final secs = zoneSecondsOf(run, zones);
    if (secs.skip(1).any((x) => x > 0)) {
      zoneMin = {for (var z = 1; z <= 5; z++) 'z$z': _r1(secs[z] / 60)};
    }
    final durationMs = run.end.difference(run.start).inMilliseconds;
    final distanceM = run.distanceM;
    final pace = distanceM > 0 ? durationMs / 1000 / (distanceM / 1000) : null;
    final tp = a?.truePace == null ? null : _dp1(a!.truePace!.trueSecPerKm);
    final elev = RunElevation.of(run);
    final climb = elev == null ? null : _dp1(elev.ascentM);
    final feel = sidecar.feel;
    out.add({
      'run_id': run.id,
      'type': mode.name,
      'start_utc': run.start.toUtc().toIso8601String(),
      'utc_offset_min': offset,
      'zone_id': zone,
      'duration_s': (durationMs / 1000).round(),
      'distance_m': _r1(distanceM),
      'pace_s_per_km': ?(pace == null ? null : _r1(pace)),
      'true_pace_s_per_km': ?(tp == null ? null : _r1(tp)),
      'verdict': ?headline,
      'zone_min': ?zoneMin,
      'climb_m': ?(climb == null ? null : _r1(climb)),
      'locality': ?sidecar.place,
      'feel': ?feel?.name,
    });
  }
  return out;
}
