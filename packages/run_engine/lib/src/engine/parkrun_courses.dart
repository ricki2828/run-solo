import '../import/import_util.dart';
import '../model/run_file.dart';

/// A known course: where its runs start (K1).
class ParkrunCourseStart {
  const ParkrunCourseStart({
    required this.courseId,
    required this.lat,
    required this.lon,
  });

  final String courseId;
  final double lat;
  final double lon;
}

/// Course auto-tagging for the Saturday 5 km event (Phase 3 §7 K1): a run
/// joins the course whose earlier start lies within [clusterRadiusM] of its
/// own start, else it starts a new course. Pure; the start points come from
/// the runs themselves (on the phone only), so the tags are rebuildable.
abstract final class ParkrunCourses {
  /// Same start line, give or take GPS lock and where the runner pressed
  /// Start.
  static const double clusterRadiusM = 150;

  /// The run's first accepted fix, or null for an indoor run.
  static ({double lat, double lon})? startOf(RunFile run) {
    for (final s in run.samples) {
      if (s.hasFix) return (lat: s.lat!, lon: s.lon!);
    }
    return null;
  }

  /// The course for [run]: the nearest [known] start within
  /// [clusterRadiusM], else a new id ([newCourseId]); null without a fix.
  static String? assign(RunFile run, Iterable<ParkrunCourseStart> known) {
    final start = startOf(run);
    if (start == null) return null;
    String? best;
    var bestM = double.infinity;
    for (final k in known) {
      final d = haversineM(start.lat, start.lon, k.lat, k.lon);
      if (d <= clusterRadiusM && d < bestM) {
        bestM = d;
        best = k.courseId;
      }
    }
    return best ?? newCourseId(run);
  }

  /// A stable id for a course first run on [run]: `c-` and the run id's
  /// first 8 hex digits. The runner names it later; the id never changes.
  static String newCourseId(RunFile run) {
    final hex = run.id.replaceAll('-', '');
    return 'c-${hex.length > 8 ? hex.substring(0, 8) : hex}';
  }
}
