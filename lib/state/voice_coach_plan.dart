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
  /// planned zone 2. Everything else gets the next-step line and nothing else.
  static VoiceCoachConfig build({
    required AppSettings settings,
    required engine.HrZones zones,
    engine.BlockSession? planned,
    double? vdot,
    double? goalPaceSecPerKm,
  }) {
    final on = settings.cues && settings.voiceCoaching;
    final full = settings.coachingDetail == CoachingDetail.full;
    final kind = planned?.kind;
    final ceiling =
        kind == engine.BlockKind.easy || kind == engine.BlockKind.long;
    double? pace = goalPaceSecPerKm;
    if (pace == null && planned != null) {
      pace = engine.BlockPaces.target(planned, vdot);
    }
    if (pace != null && !(pace.isFinite && pace > 0)) pace = null;
    final easy = kind == engine.BlockKind.easy;
    return VoiceCoachConfig(
      enabled: on,
      full: full,
      slowerIsFine: goalPaceSecPerKm == null && ceiling,
      targetPaceSecPerKm: on && full ? pace : null,
      zoneBottomsBpm: on && full && easy
          ? [for (var z = 2; z <= 5; z++) zones.bottom(z).toDouble()]
          : null,
      plannedMaxZone: on && full && easy ? 2 : null,
    );
  }

  /// "Off" for a run that must not be coached (never started).
  static VoiceCoachConfig get off =>
      VoiceCoachConfig(enabled: false, full: false, slowerIsFine: false);
}
