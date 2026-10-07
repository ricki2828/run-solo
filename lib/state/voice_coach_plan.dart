/// What the voice coach is told at Start (Settings → Voice → "Voice coaching").
/// Pure: the Start screen passes in what it already knows, the recorder
/// service reads the result natively so the lines work with the screen off.
library;

import 'package:run_engine/run_engine.dart' as engine;

import '../platform/gateway.dart';
import 'settings.dart';

abstract final class VoiceCoachPlan {
  /// The config for the run about to start.
  ///
  /// [planned] is the plan session being run (null for any other run) and
  /// [vdot] the plan's fitness estimate. [goalPaceSecPerKm] is a goal run's
  /// own pace (target time over distance); it wins over the plan's estimate.
  /// [zones] gives the zone bottoms drift is measured against.
  ///
  /// Target status: a goal's pace, or a plan session's True Pace estimate
  /// (interval reps, goal, easy, long). Easy and long paces are "or slower",
  /// so slow counts as on target there. Zone drift: plan easy sessions only,
  /// planned zone 2 (and Home's warned "Start Easy run", [warnedEasy]). Everything else gets the next-step line and nothing else.
  static VoiceCoachConfig build({
    required AppSettings settings,
    required engine.HrZones zones,
    engine.BlockSession? planned,
    bool warnedEasy = false,
    double? vdot,
    double? goalPaceSecPerKm,
  }) {
    final on = settings.cues && settings.voiceCoaching;
    final full = settings.coachingDetail == CoachingDetail.full;
    final kind = planned?.kind;
    final pace = _pace(planned, vdot, goalPaceSecPerKm);
    // Home's warned "Start Easy run" is an easy run with no plan session:
    // no pace, but heart rate is held to zone 2 like a plan easy session.
    final easy = kind == engine.BlockKind.easy || warnedEasy;
    return VoiceCoachConfig(
      enabled: on,
      full: full,
      slowerIsFine: goalPaceSecPerKm == null && _ceiling(kind),
      targetPaceSecPerKm: on && full ? pace : null,
      zoneBottomsBpm: on && full && easy
          ? [for (var z = 2; z <= 5; z++) zones.bottom(z).toDouble()]
          : null,
      plannedMaxZone: on && full && easy ? 2 : null,
    );
  }

  /// The run screen's target band: the same pace the voice judges, but shown
  /// whether or not voice coaching is on. Null = no target (Free runs and
  /// plan sessions without a pace show no band).
  static CoachTarget? target({
    engine.BlockSession? planned,
    double? vdot,
    double? goalPaceSecPerKm,
  }) {
    final pace = _pace(planned, vdot, goalPaceSecPerKm);
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
    double? goalPaceSecPerKm,
  ) {
    double? pace = goalPaceSecPerKm;
    if (pace == null && planned != null) {
      pace = engine.BlockPaces.target(planned, vdot);
    }
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
