/// What the voice coach is told at Start (Settings → Voice → "Voice coaching").
/// Pure: the Start screen passes in what it already knows, the recorder
/// service reads the result natively so the lines work with the screen off.
library;

import 'package:run_engine/run_engine.dart' as engine;

import '../platform/gateway.dart';
import 'settings.dart';
import 'start_briefing.dart';

abstract final class VoiceCoachPlan {
  /// The config for the run about to start.
  ///
  /// [planned] is the plan session being run (null for any other run) and
  /// [vdot] the plan's fitness estimate. [goalPaceSecPerKm] is a goal run's
  /// own pace (target time over distance); it wins over the plan's estimate.
  /// [sessionPaceSecPerKm] is the target pace of a hand-picked preset (see
  /// `TargetPaces`) as True Pace, with no heat added: the live pace the coach
  /// compares it with is True Pace too. A goal or plan session wins over it.
  /// [paces] is the one source for plan sessions; [vdot] is only the fallback
  /// before there are any runs.
  /// [zones] gives the zone bottoms drift is measured against.
  ///
  /// Target status: a goal's pace, or a plan session's True Pace estimate
  /// (interval reps, goal, easy, long). Easy and long paces are "or slower",
  /// so slow counts as on target there. Zone drift: plan easy sessions only,
  /// planned zone 2 (and Home's warned "Start Easy run", [warnedEasy]).
  ///
  /// Planned time: an easy or long plan session with minutes also carries
  /// them ([VoiceCoachConfig.plannedKind], [VoiceCoachConfig.plannedMinutes]),
  /// so the recorder says "Halfway." (planned 20 minutes or more) and
  /// "5 minutes to go." (15 or more) on moving time (pauses excluded), and nothing
  /// past the planned time. Free, goal, interval and trail runs carry no planned kind
  /// (an interval session's minutes ride along only for the start briefing).
  /// Any other run gets the next-step line only.
  ///
  /// Start briefing: a plan session (easy, long or intervals; never a goal run) at full detail also carries
  /// the app's own briefing template ([VoiceCoachConfig.briefingFallback]) and what its slots speak
  /// (minutes, a long run's distance, reps, the spoken session name; the pace is [targetPaceSecPerKm]), so the
  /// recorder says it in the runner's units. [briefingTemplate] is the coach's own template for that session,
  /// already matched to it by the caller (null until the app fetches one): it is spoken first, the app's own
  /// when it does not render. Nothing here waits for the network: both are plain strings already in hand.
  /// Free, goal, event, Cooper, laps and trail runs carry none and keep their usual start line.
  static VoiceCoachConfig build({
    required AppSettings settings,
    required engine.HrZones zones,
    engine.BlockSession? planned,
    bool warnedEasy = false,
    double? vdot,
    double? goalPaceSecPerKm,
    double? sessionPaceSecPerKm,
    engine.TargetPaces? paces,
    String? briefingTemplate,
  }) {
    final on = settings.cues && settings.voiceCoaching;
    final full = settings.coachingDetail == CoachingDetail.full;
    final kind = planned?.kind;
    final pace = _pace(
      planned,
      vdot,
      goalPaceSecPerKm,
      sessionPaceSecPerKm,
      paces,
    );
    // Home's warned "Start Easy run" is an easy run with no plan session:
    // no pace, but heart rate is held to zone 2 like a plan easy session.
    final easy = kind == engine.BlockKind.easy || warnedEasy;
    final minutes = planned?.minutes;
    final timed = _ceiling(kind) && minutes != null && minutes > 0;
    final briefing = on && full
        ? StartBriefing.plan(planned, hasPace: pace != null)
        : null;
    return VoiceCoachConfig(
      enabled: on,
      full: full,
      slowerIsFine: goalPaceSecPerKm == null && _ceiling(kind),
      targetPaceSecPerKm: on && full ? pace : null,
      // Every full-detail run gets the zones, for the first-time zone-up line; only an easy run gets drift.
      zoneBottomsBpm: on && full
          ? [for (var z = 2; z <= 5; z++) zones.bottom(z).toDouble()]
          : null,
      plannedMaxZone: on && full && easy ? 2 : null,
      plannedKind: on && full && timed ? kind!.name : null,
      // Intervals carry their minutes too, for the briefing's {minutes}: with no plannedKind the recorder
      // has no planned-time lines for them.
      plannedMinutes: on && full && timed ? minutes : briefing?.minutes,
      briefingTemplate: briefing == null ? null : briefingTemplate,
      briefingFallback: briefing?.fallback,
      plannedDistanceM: briefing?.distanceM,
      reps: briefing?.reps,
      sessionName: briefing?.sessionName,
    );
  }

  /// What the km check-in is told: the runner's chosen metric keys and the zone
  /// 2 to 5 bottoms by their own HR method (the same zones the run screen and
  /// the drift line use). Not tied to the plan: a check-in only exists on Free
  /// and Trail runs, which have no target pace, so its pace is the raw km pace
  /// and True Pace is its own metric.
  static ({List<String> metrics, List<double> zoneBottomsBpm}) checkIn({
    required AppSettings settings,
    required engine.HrZones zones,
  }) => (
    metrics: [
      for (final m in settings.checkInMetrics) m.key,
      settings.voiceDetail.metricKey,
    ],
    zoneBottomsBpm: [for (var z = 2; z <= 5; z++) zones.bottom(z).toDouble()],
  );

  /// The run screen's target band: the same pace the voice judges, but shown
  /// whether or not voice coaching is on. Null = no target (Free runs and
  /// plan sessions without a pace show no band).
  static CoachTarget? target({
    engine.BlockSession? planned,
    double? vdot,
    double? goalPaceSecPerKm,
    double? sessionPaceSecPerKm,
    engine.TargetPaces? paces,
  }) {
    final pace = _pace(
      planned,
      vdot,
      goalPaceSecPerKm,
      sessionPaceSecPerKm,
      paces,
    );
    if (pace == null) return null;
    return CoachTarget(
      paceSecPerKm: pace,
      slowerIsFine: goalPaceSecPerKm == null && _ceiling(planned?.kind),
    );
  }

  static bool _ceiling(engine.BlockKind? kind) =>
      kind == engine.BlockKind.easy || kind == engine.BlockKind.long;

  static double? _pace(
    engine.BlockSession? planned,
    double? vdot,
    double? goalPaceSecPerKm, [
    double? sessionPaceSecPerKm,
    engine.TargetPaces? paces,
  ]) {
    double? pace = goalPaceSecPerKm;
    if (pace == null && planned != null) {
      pace =
          paces?.sessionPace(planned) ??
          engine.BlockPaces.target(planned, vdot);
    }
    // A preset set with no plan session behind it (a Norwegian 4x4 picked
    // by hand): the runner's own target pace for that effort.
    pace ??= planned == null ? sessionPaceSecPerKm : null;
    return pace != null && pace.isFinite && pace > 0 ? pace : null;
  }

  /// "Off" for a run that must not be coached (never started).
  static VoiceCoachConfig get off =>
      VoiceCoachConfig(enabled: false, full: false, slowerIsFine: false);
}

/// The pace a session is aiming at, for the run screen's target band bar.
/// [slowerIsFine]: an easy or long run's pace is a ceiling, slower is on
/// target (the band then shows only its fast edge as a limit).
class CoachTarget {
  const CoachTarget({
    required this.paceSecPerKm,
    this.slowerIsFine = false,
    this.bandSecPerKm = 5,
  });
  final double paceSecPerKm;
  final bool slowerIsFine;

  /// Half-width of the on-target band: the coach's default of 5 s/km.
  final double bandSecPerKm;
}
