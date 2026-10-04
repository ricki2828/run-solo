/// The zones the app uses, from settings (Settings → Heart rate zones).
/// One resolver so the live screen, run detail and Settings agree.
library;

import 'package:run_engine/run_engine.dart' as engine;

import 'max_hr.dart';
import 'settings.dart';

abstract final class HrZoneChoice {
  /// The zones for [s]: the chosen method when its inputs are complete,
  /// otherwise share of max HR (so a half-filled setting never breaks a run).
  static engine.HrZones resolve(AppSettings s, DateTime now) {
    final max = MaxHr.resolve(s, now).maxHr;
    switch (s.hrZoneMethod) {
      case engine.HrZoneMethod.reserve:
        final rest = s.restingHr;
        if (rest != null && rest < max) {
          return engine.HrZones.reserve(rest, max);
        }
      case engine.HrZoneMethod.custom:
        final c = s.customZones;
        if (c != null) {
          return engine.HrZones.custom(c.sublist(1), z1Floor: c[0]);
        }
      case engine.HrZoneMethod.percentMax:
        break;
    }
    return engine.HrZones.percentMax(max);
  }
}
