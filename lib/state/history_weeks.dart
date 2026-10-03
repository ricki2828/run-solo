import 'package:run_engine/run_engine.dart' as engine;

import '../platform/gateway.dart';
import 'history_store.dart';

/// One History section: a week ("THIS WEEK", "22 TO 28 SEP") or, for older
/// runs, a month ("AUGUST 2026"), with the totals of the runs in it.
class HistoryGroup {
  const HistoryGroup({required this.header, required this.runs});

  final String header;

  /// Newest first; empty only for the "This week" anchor.
  final List<RunSummary> runs;

  int get count => runs.length;

  double get distanceM => runs.fold(0.0, (a, r) => a + r.distanceM);

  /// Moving time from the index row, the elapsed time without one.
  int get movingMs =>
      runs.fold(0, (a, r) => a + (r.row?.movingMs ?? r.durationMs));

  /// Total climb in metres; 0 when no run has an elevation figure.
  double get climbM => runs.fold(0.0, (a, r) => a + (r.row?.climbM ?? 0));

  /// "4 runs · 32.4 km · 3:05 · +410 m" (climb left out when there is none).
  String totals(Units units) {
    final mi = units == Units.mi;
    final dist = mi
        ? distanceM / engine.PaceFormat.metresPerMile
        : distanceM / 1000;
    final mins = (movingMs / 60000).round();
    final climb = mi ? climbM * 3.28084 : climbM;
    return [
      count == 1 ? '1 run' : '$count runs',
      '${dist.toStringAsFixed(1)} ${mi ? 'mi' : 'km'}',
      '${mins ~/ 60}:${(mins % 60).toString().padLeft(2, '0')}',
      if (climb.round() > 0) '+${climb.round()} ${mi ? 'ft' : 'm'}',
    ].join(' · ');
  }
}

/// Weeks back that still get their own date range; older runs fall to months.
const int historyWeeksBack = 8;

const _months = [
  'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN',
  'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC', //
];
const _monthsFull = [
  'JANUARY', 'FEBRUARY', 'MARCH', 'APRIL', 'MAY', 'JUNE',
  'JULY', 'AUGUST', 'SEPTEMBER', 'OCTOBER', 'NOVEMBER', 'DECEMBER', //
];

/// Whole days since the epoch of [d]'s wall-clock date (zone and DST free).
int _day(DateTime d) =>
    DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch ~/ 86400000;

DateTime _date(int day) =>
    DateTime.fromMillisecondsSinceEpoch(day * 86400000, isUtc: true);

/// The Monday on or before [day].
int _monday(int day) => day - (_date(day).weekday - 1);

String _range(int monday) {
  final a = _date(monday);
  final b = _date(monday + 6);
  return a.month == b.month
      ? '${a.day} TO ${b.day} ${_months[b.month - 1]}'
      : '${a.day} ${_months[a.month - 1]} TO ${b.day} ${_months[b.month - 1]}';
}

/// Groups [runs] into weeks (Monday start), newest first. A run belongs to
/// the week of its own local date ([RunSummary.localStart]: where the runner
/// was, never the phone's zone now); [now] only anchors "this week" and is
/// read as the phone's wall clock. Empty weeks are skipped, except "This
/// week", which is always the first group so the current week is anchored.
List<HistoryGroup> groupByWeek(List<RunSummary> runs, DateTime now) {
  final thisMonday = _monday(_day(now));
  final sorted = [...runs]
    ..sort((a, b) => b.localStart.compareTo(a.localStart));
  final keys = <String>[];
  final buckets = <String, List<RunSummary>>{};
  void add(String header, RunSummary r) {
    (buckets[header] ??= []).add(r);
    if (!keys.contains(header)) keys.add(header);
  }

  for (final r in sorted) {
    final local = r.localStart;
    final monday = _monday(_day(local));
    // A run dated ahead of the phone's clock (a zone skew) is still "this
    // week".
    final back = ((thisMonday - monday) / 7).round().clamp(0, 1 << 20);
    if (back == 0) {
      add('THIS WEEK', r);
    } else if (back == 1) {
      add('LAST WEEK', r);
    } else if (back <= historyWeeksBack && local.year == now.year) {
      add(_range(monday), r);
    } else {
      add('${_monthsFull[local.month - 1]} ${local.year}', r);
    }
  }
  return [
    if (!buckets.containsKey('THIS WEEK'))
      const HistoryGroup(header: 'THIS WEEK', runs: []),
    for (final k in keys) HistoryGroup(header: k, runs: buckets[k]!),
  ];
}
