/// K1 app half: course names (`files/state/courses.json`), official-time
/// entry checks and the per-course board fold. The engine owns course ids
/// (`ParkrunCourses`) and the official-time rules; names are app state only
/// and never go in a sidecar. The event's own name only ever comes from
/// `kEventNames` (tools/check_event_names.py).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:run_engine/run_engine.dart' as engine;

import 'history_store.dart';

abstract class CourseNamesStore {
  Future<Map<String, String>> load();
  Future<void> save(Map<String, String> names);
}

class MemoryCourseNamesStore implements CourseNamesStore {
  MemoryCourseNamesStore([Map<String, String>? initial])
    : names = {...?initial};
  Map<String, String> names;

  @override
  Future<Map<String, String>> load() async => {...names};

  @override
  Future<void> save(Map<String, String> names) async => this.names = {...names};
}

/// `{"schema": 1, "names": {id: name}}`; a missing or damaged file reads as
/// no names (every course shows its default label).
class FileCourseNamesStore implements CourseNamesStore {
  FileCourseNamesStore(this.stateDir);
  final Directory stateDir;
  static const int schema = 1;

  File get file => File('${stateDir.path}/courses.json');

  @override
  Future<Map<String, String>> load() async {
    try {
      if (!await file.exists()) return {};
      final j = jsonDecode(await file.readAsString());
      if (j is! Map || j['names'] is! Map) return {};
      return {
        for (final e in (j['names'] as Map).entries)
          if (e.key is String && e.value is String && '${e.value}'.isNotEmpty)
            e.key as String: e.value as String,
      };
    } catch (e) {
      debugPrint('courses: damaged file, no names ($e)');
      return {};
    }
  }

  @override
  Future<void> save(Map<String, String> names) async {
    await stateDir.create(recursive: true);
    final tmp = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await tmp.writeAsString(
      jsonEncode({'schema': schema, 'names': names}),
      flush: true,
    );
    await tmp.rename(file.path);
  }
}

class CourseNamesController extends ChangeNotifier {
  CourseNamesController(this._store);
  final CourseNamesStore _store;
  Map<String, String> _names = const {};
  Future<void> _writes = Future.value();

  static const int maxLength = 40;

  Future<void> load() async {
    _names = await _store.load();
    notifyListeners();
  }

  /// Synchronous seed for tests and the fake APK.
  void preload(Map<String, String> names) => _names = {...names};

  /// The runner's name, or null (callers fall back to [CourseLabels]).
  String? nameOf(String courseId) => _names[courseId];

  /// Blank clears the name back to the default label.
  Future<void> rename(String courseId, String name) {
    final n = name.trim();
    final clipped = n.length > maxLength ? n.substring(0, maxLength) : n;
    _names = {..._names};
    if (clipped.isEmpty) {
      _names.remove(courseId);
    } else {
      _names[courseId] = clipped;
    }
    notifyListeners();
    final snapshot = {..._names};
    return _writes = _writes.then((_) => _store.save(snapshot));
  }
}

/// A run's course: the sidecar tag (memory store, loaded runs) or its
/// comparison key `<event key>:<id>` (the index, W5b).
String? courseIdOf(RunSummary r) {
  if (!r.isParkrun) return null;
  final tagged = r.parkrun?.courseId;
  if (tagged != null) return tagged;
  final key = r.comparisonKey;
  const prefix = '${engine.ComparisonKey.parkrun}:';
  return key != null && key.startsWith(prefix)
      ? key.substring(prefix.length)
      : null;
}

/// Default labels: "Course 1", "Course 2" … in order of each course's first
/// run, so they stay put as runs are added.
class CourseLabels {
  CourseLabels(List<RunSummary> runs, this.names) : _order = _orderOf(runs);
  final CourseNamesController names;
  final List<String> _order;

  static List<String> _orderOf(List<RunSummary> runs) {
    final first = <String, DateTime>{};
    for (final r in runs) {
      final id = courseIdOf(r);
      if (id == null) continue;
      final have = first[id];
      if (have == null || r.start.isBefore(have)) first[id] = r.start;
    }
    return first.keys.toList()..sort((a, b) => first[a]!.compareTo(first[b]!));
  }

  /// Oldest first.
  List<String> get courseIds => _order;

  String labelOf(String courseId) {
    final n = names.nameOf(courseId);
    if (n != null) return n;
    final i = _order.indexOf(courseId);
    return i < 0 ? 'New course' : 'Course ${i + 1}';
  }
}

/// Parses "23:20", "23.20" or "1:02:05"; null when it is not a time.
int? parseFinishTime(String text) {
  final parts = text.trim().split(RegExp(r'[:.]'));
  if (parts.length < 2 || parts.length > 3) return null;
  final nums = parts.map(int.tryParse).toList();
  if (nums.any((n) => n == null || n < 0)) return null;
  final v = nums.cast<int>();
  if (v.skip(1).any((n) => n > 59)) return null;
  final s = v.length == 3 ? v[0] * 3600 + v[1] * 60 + v[2] : v[0] * 60 + v[1];
  return s > 0 ? s : null;
}

/// The GPS finish of an event run, seconds: the one 5 km rep as measured,
/// which the official time never replaces.
double? gpsFinishSeconds(engine.IntervalMetrics? m) {
  if (m == null || m.nominalRepMetres == null) return null;
  final pace = m.reps.isEmpty ? null : m.reps.first.paceSecPerKm;
  if (pace == null) return m.avgRepSeconds;
  return pace * m.nominalRepMetres! / 1000;
}

/// Why an official time cannot be used, or null when it is fine: the
/// engine's own rule (`ParkrunInfo.officialTimeProblem`, 12:00 to 1:30:00
/// and within 20% of the GPS finish), so the entry screen and the verdict
/// never disagree. Said plainly rather than dropped silently.
String? officialTimeProblem(int? seconds, double? gpsSeconds) {
  if (seconds == null) {
    return 'Type the time as minutes and seconds, like 23:20.';
  }
  return engine.ParkrunInfo.officialTimeProblem(
    seconds,
    gpsSeconds: gpsSeconds,
  );
}

@immutable
class CourseBoardEntry {
  const CourseBoardEntry({
    required this.run,
    required this.finishSeconds,
    required this.official,
    this.heatAdjustedSeconds,
  });
  final RunSummary run;

  /// Official when entered and used, else the GPS finish.
  final double finishSeconds;
  final bool official;

  /// The heat-adjusted twin (W1); null without weather, never estimated.
  final double? heatAdjustedSeconds;
}

/// One course's board (plan §7 K1: best, last 5, trend, heat column). A fold
/// over History until LB2's boards land.
@immutable
class CourseBoard {
  const CourseBoard({
    required this.courseId,
    required this.ranked,
    required this.last5,
    this.trendSecPerMonth,
  });
  final String courseId;

  /// Fastest first; ties go to the earlier date.
  final List<CourseBoardEntry> ranked;

  /// Newest first.
  final List<CourseBoardEntry> last5;

  /// Theil–Sen over the last 8 entries, seconds per 30 days (negative =
  /// quicker); null with fewer than 4 entries in 90 days.
  final double? trendSecPerMonth;

  CourseBoardEntry? get best => ranked.isEmpty ? null : ranked.first;

  /// 1-based rank of [runId], or null when it is not on the board.
  int? rankOf(String runId) {
    final i = ranked.indexWhere((e) => e.run.id == runId);
    return i < 0 ? null : i + 1;
  }

  static CourseBoard fold(
    List<RunSummary> runs,
    String courseId, {
    required DateTime now,
  }) {
    final entries = <CourseBoardEntry>[];
    for (final r in runs) {
      if (courseIdOf(r) != courseId || r.missing) continue;
      final pace = r.workPaceSecPerKm;
      final nominal = r.spec?.steps.isEmpty ?? true
          ? null
          : r.spec!.steps.first.value;
      if (pace == null || nominal == null) continue;
      // Same gates as verdicts: indoor, noisy or flagged runs stay off.
      if (!r.eligibleAsPrior) continue;
      final finish = pace * nominal / 1000;
      final entered = r.parkrun?.officialTimeSeconds;
      final heat = r.analysis?.heatAdjustedWorkPaceSecPerKm;
      entries.add(
        CourseBoardEntry(
          run: r,
          finishSeconds: finish,
          official:
              r.indexedOfficialTime ??
              (entered != null && (finish - entered).abs() < 0.5),
          // The index carries no heat twin yet: blank, never estimated.
          heatAdjustedSeconds: heat == null ? null : heat * nominal / 1000,
        ),
      );
    }
    final ranked = List.of(entries)
      ..sort((a, b) {
        final c = a.finishSeconds.compareTo(b.finishSeconds);
        return c != 0 ? c : a.run.start.compareTo(b.run.start);
      });
    final newest = List.of(entries)
      ..sort((a, b) => b.run.start.compareTo(a.run.start));
    return CourseBoard(
      courseId: courseId,
      ranked: ranked,
      last5: newest.take(5).toList(),
      trendSecPerMonth: _trend(newest, now),
    );
  }

  static double? _trend(List<CourseBoardEntry> newestFirst, DateTime now) {
    final recent = newestFirst
        .where((e) => now.difference(e.run.start).inDays <= 90)
        .length;
    if (recent < 4) return null;
    final pts = [
      for (final e in newestFirst.take(8))
        (e.run.start.millisecondsSinceEpoch / 86400000.0, e.finishSeconds),
    ];
    final slopes = <double>[];
    for (var i = 0; i < pts.length; i++) {
      for (var j = i + 1; j < pts.length; j++) {
        final dx = pts[j].$1 - pts[i].$1;
        if (dx == 0) continue;
        slopes.add((pts[j].$2 - pts[i].$2) / dx);
      }
    }
    if (slopes.isEmpty) return null;
    slopes.sort();
    final n = slopes.length;
    final median = n.isOdd
        ? slopes[n ~/ 2]
        : (slopes[n ~/ 2 - 1] + slopes[n ~/ 2]) / 2;
    return median * 30;
  }
}
