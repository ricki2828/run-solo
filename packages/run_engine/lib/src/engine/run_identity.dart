import '../import/import_util.dart';
import '../model/run_file.dart';
import 'parkrun_courses.dart';

/// Where and when a run happened, as a person would say it: a time-of-day
/// word for the title and a short place name for the start point. Pure; the
/// place name itself comes from the phone's geocoder (never from here).
abstract final class RunIdentity {
  /// A new run starting this close to an earlier run's start reuses that
  /// run's place name, so one park is not "Albert Park" one day and "St
  /// Kilda Rd" the next.
  static const double placeReuseRadiusM = 300;

  /// "Early" before 7, "Morning" before 11, "Lunch" before 14, "Afternoon"
  /// before 17, "Evening" before 21, "Night" after. [local] is the run's
  /// start in the phone's own time zone.
  static String timeOfDay(DateTime local) {
    final h = local.hour;
    if (h < 7) return 'Early';
    if (h < 11) return 'Morning';
    if (h < 14) return 'Lunch';
    if (h < 17) return 'Afternoon';
    if (h < 21) return 'Evening';
    return 'Night';
  }

  /// "Morning Norwegian 4x4": the time-of-day word and the session's name.
  static String title(DateTime local, String sessionName) =>
      '${timeOfDay(local)} $sessionName';

  /// The run's first accepted fix; null for an indoor run.
  static ({double lat, double lon})? startOf(RunFile run) =>
      ParkrunCourses.startOf(run);

  /// The place name of the earliest-listed [known] start within
  /// [placeReuseRadiusM] of ([lat], [lon]) that has one; the nearest wins.
  /// Null when none is close enough.
  static String? reusePlace(
    double lat,
    double lon,
    Iterable<({double lat, double lon, String place})> known,
  ) {
    String? best;
    var bestM = double.infinity;
    for (final k in known) {
      final d = haversineM(lat, lon, k.lat, k.lon);
      if (d <= placeReuseRadiusM && d < bestM) {
        bestM = d;
        best = k.place;
      }
    }
    return best;
  }

  /// A geocoder's answer cleaned up for display: trimmed, empty is null.
  /// A string that is just numbers (a raw coordinate or a house number) is
  /// not a place and is dropped, so a coordinate can never be shown.
  static String? cleanPlace(String? raw) {
    final s = raw?.trim();
    if (s == null || s.isEmpty) return null;
    if (RegExp(r'^[\d\s.,;:+\-°NSEWnsew]+$').hasMatch(s)) return null;
    return s.length > 40 ? s.substring(0, 40).trim() : s;
  }

  /// A user's rename, trimmed and capped; null (use the automatic title)
  /// when empty.
  static String? cleanTitle(String? raw) {
    final s = raw?.trim();
    if (s == null || s.isEmpty) return null;
    return s.length > 40 ? s.substring(0, 40).trim() : s;
  }
}
