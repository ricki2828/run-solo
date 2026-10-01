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

  /// A street is only reused this close: a street name is not true across a
  /// neighbourhood the way an area name is.
  static const double streetReuseRadiusM = 60;

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

  /// The wall-clock start as the runner lived it: [startUtc] shifted by the
  /// UTC offset recorded when the run finished, so a run in another time
  /// zone (or before a clock change) keeps its own morning. Without one
  /// (a run from before the offset was recorded) the phone's current zone.
  /// Read the hour and minute off the result; its zone flag is not meaningful.
  static DateTime localStart(DateTime startUtc, int? utcOffsetMin) =>
      utcOffsetMin == null
      ? startUtc.toLocal()
      : startUtc.toUtc().add(Duration(minutes: utcOffsetMin));

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

  /// The street of the nearest [known] start within [streetReuseRadiusM] of
  /// ([lat], [lon]) that has one. Null when none is close enough.
  static String? reuseStreet(
    double lat,
    double lon,
    Iterable<({double lat, double lon, String street})> known,
  ) {
    String? best;
    var bestM = double.infinity;
    for (final k in known) {
      final d = haversineM(lat, lon, k.lat, k.lon);
      if (d <= streetReuseRadiusM && d < bestM) {
        bestM = d;
        best = k.street;
      }
    }
    return best;
  }

  /// A geocoder's street cleaned up for display: a street name, never a
  /// house number (a leading "12 " is cut), and null for blank, numeric or
  /// unnamed roads. Abbreviations are the geocoder's own; none are added.
  static String? cleanStreet(String? raw) {
    var s = raw?.trim();
    if (s == null) return null;
    s = s
        .replaceFirst(RegExp(r'^\d+[a-zA-Z]?([/-]\d+[a-zA-Z]?)?\s+'), '')
        .trim();
    if (!RegExp(r'\p{L}', unicode: true).hasMatch(s)) return null;
    if (RegExp(r'^unnamed', caseSensitive: false).hasMatch(s)) return null;
    return cleanPlace(s);
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
