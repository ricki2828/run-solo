import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/services.dart';
import '../platform/gateway.dart' show Units;
import '../state/load_source.dart';
import '../theme/theme.dart';
import '../widgets/chrome.dart';
import '../widgets/choice_chips.dart';
import '../widgets/load_bars.dart';
import '../widgets/recent_bars_chart.dart' show ChartEmptyState;
import 'weekly_load_page.dart' show loadWeekLabels;

const _months = [
  'JAN',
  'FEB',
  'MAR',
  'APR',
  'MAY',
  'JUN',
  'JUL',
  'AUG',
  'SEP',
  'OCT',
  'NOV',
  'DEC',
];

/// Everything the Load trends draw: the last 8 weeks (the last one is the
/// week still being run), the last 6 calendar months and this year.
class LoadTrendsData {
  const LoadTrendsData({
    required this.weeks,
    required this.months,
    required this.year,
    required this.hasRuns,
  });

  factory LoadTrendsData.from(LoadSource src) => LoadTrendsData(
    weeks: src.weeks(8),
    months: src.months(6),
    year: src.year(),
    hasRuns: src.runs.any((r) => !r.missing),
  );

  final List<engine.WeekLoad> weeks;
  final List<engine.PeriodLoad> months;
  final engine.YearLoad year;
  final bool hasRuns;
}

/// History > Trends > Load: load by week, month and year. Reads History
/// itself unless [data] is passed (tests and goldens).
class LoadTrends extends StatefulWidget {
  const LoadTrends({super.key, this.data});
  final LoadTrendsData? data;

  @override
  State<LoadTrends> createState() => _LoadTrendsState();
}

class _LoadTrendsState extends State<LoadTrends> {
  Future<LoadTrendsData>? _data;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final d = widget.data;
    _data ??= d != null
        ? Future.value(d)
        : LoadSource.read(AppServices.of(context)).then(LoadTrendsData.from);
  }

  @override
  Widget build(BuildContext context) {
    final units = AppServices.of(context).settings.settings.units;
    return FutureBuilder<LoadTrendsData>(
      future: _data,
      builder: (context, snap) {
        final data = snap.data;
        if (data == null) {
          // Failed reads fall back to the empty state, not a spinner.
          return snap.hasError
              ? const _Empty()
              : const SizedBox(key: ValueKey('load-loading'), height: 120);
        }
        return data.hasRuns
            ? LoadTrendsView(data: data, units: units)
            : const _Empty();
      },
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) => const ChartEmptyState(
    key: ValueKey('load-empty'),
    title: 'Your load builds from your first run.',
  );
}

/// The three-way Week / Month / Year view. Pure: [data] in, widgets out.
class LoadTrendsView extends StatefulWidget {
  const LoadTrendsView({super.key, required this.data, required this.units});
  final LoadTrendsData data;
  final Units units;

  @override
  State<LoadTrendsView> createState() => _LoadTrendsViewState();
}

class _LoadTrendsViewState extends State<LoadTrendsView> {
  int _view = 0;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final d = widget.data;
    final (tiles, chart, notes) = switch (_view) {
      0 => _week(d.weeks, t),
      1 => _month(d.months, t),
      _ => _year(d.year, t),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ChoiceChips(
          labels: const ['Week', 'Month', 'Year'],
          keys: const [
            ValueKey('load-view-week'),
            ValueKey('load-view-month'),
            ValueKey('load-view-year'),
          ],
          selected: _view,
          onSelect: (i) => setState(() => _view = i),
        ),
        const SizedBox(height: Space.x24),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < tiles.length; i++)
              Expanded(
                child: StatTile(
                  key: ValueKey('load-tile-$i'),
                  label: tiles[i].$1,
                  value: tiles[i].$2,
                ),
              ),
          ],
        ),
        const SizedBox(height: Space.x16),
        DecoratedBox(
          decoration: BoxDecoration(
            color: t.bgRaised,
            borderRadius: BorderRadius.circular(Radii.card),
            border: Border.all(color: t.lineHair),
          ),
          child: Padding(
            padding: const EdgeInsets.all(Space.cardPadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                chart,
                const SizedBox(height: Space.x8),
                Text(
                  'Taller is more load',
                  style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                ),
              ],
            ),
          ),
        ),
        ...notes,
      ],
    );
  }

  String _km(double km) {
    final mi = widget.units == Units.mi;
    final v = mi ? km * 1000 / engine.PaceFormat.metresPerMile : km;
    return v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  }

  String get _kmLabel => widget.units == Units.mi ? 'MI' : 'KM';

  static String _time(double minutes) {
    final m = minutes.round();
    return '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}';
  }

  Widget _caption(String text, RunSoloTokens t, {Key? key}) => Padding(
    padding: const EdgeInsets.only(top: Space.x12),
    child: Text(
      text,
      key: key,
      style: RunSoloType.body15.copyWith(color: t.inkSecondary),
    ),
  );

  /// [w] with `current` off, so `LoadCompare.of` will read its usual.
  static engine.WeekLoad _complete(engine.WeekLoad w) => engine.WeekLoad(
    monday: w.monday,
    load: w.load,
    km: w.km,
    minutes: w.minutes,
    hardMinutes: w.hardMinutes,
    runs: w.runs,
    longestKm: w.longestKm,
    hrRuns: w.hrRuns,
    zoneShare: w.zoneShare,
    noHrShare: w.noHrShare,
    basisShare: w.basisShare,
    paused: w.paused,
    beforeStart: w.beforeStart,
    partialStart: w.partialStart,
    guardFlagged: w.guardFlagged,
  );

  (List<(String, String)>, Widget, List<Widget>) _week(
    List<engine.WeekLoad> weeks,
    RunSoloTokens t,
  ) {
    final now = weeks.last;
    // The part week is never judged: the compare gets it as the week to set
    // against its usual only so that the usual (the 4 weeks before it) is
    // read from the engine's rules. Its band is not shown.
    final compare = engine.LoadCompare.of([
      ...weeks.sublist(0, weeks.length - 1),
      _complete(now),
    ]);
    final usualOk = compare.state == engine.LoadCompareState.ok;
    final n = weeks.length;
    final labels = loadWeekLabels([for (final w in weeks) w.monday]);
    return (
      [
        ('LOAD SO FAR', '${now.load.round()}'),
        ('USUAL WEEK', usualOk ? '${compare.usual.round()}' : '—'),
        (_kmLabel, _km(now.km)),
      ],
      LoadBars(
        key: const ValueKey('load-bars'),
        usual: usualOk ? compare.usual : null,
        usualFrom: (n - 5).clamp(0, n - 1),
        usualTo: n - 2,
        semanticsLabel: usualOk
            ? 'Load by week. This week so far ${now.load.round()}, '
                  'usual ${compare.usual.round()}.'
            : 'Load by week. This week so far ${now.load.round()}.',
        bars: [
          for (var i = 0; i < n; i++)
            LoadBarData.week(
              weeks[i],
              label: labels[i],
              outline: weeks[i].current
                  ? LoadBarOutline.dashed
                  : LoadBarOutline.none,
              tag: weeks[i].current ? 'SO FAR' : null,
            ),
        ],
      ),
      [
        if (compare.state == engine.LoadCompareState.firstWeeks)
          _caption('Usual week ${engine.LoadWords.afterThreeWeeks}.', t)
        else if (compare.state == engine.LoadCompareState.returning)
          _caption('Usual week ${engine.LoadWords.backThreeWeeks}.', t),
      ],
    );
  }

  (List<(String, String)>, Widget, List<Widget>) _month(
    List<engine.PeriodLoad> months,
    RunSoloTokens t,
  ) {
    final now = months.last;
    final n = months.length;
    // One baseline for the line and the sentence: last month (the last
    // complete one) against the 3 months before it. The month being run is
    // never judged, so the line stops at last month's bar.
    final lastDone = n >= 2 ? months[n - 2] : null;
    final compare = lastDone == null
        ? const engine.LoadCompare(state: engine.LoadCompareState.firstWeeks)
        : engine.LoadCompare.months(months.sublist(0, n - 1));
    final usualOk = compare.state == engine.LoadCompareState.ok;
    final line = lastDone == null || lastDone.runs == 0
        ? null
        : engine.LoadWords.monthLine(compare);
    return (
      [
        ('LOAD', '${now.load.round()}'),
        (_kmLabel, _km(now.km)),
        ('TIME', _time(now.minutes)),
      ],
      LoadBars(
        key: const ValueKey('load-bars'),
        usual: usualOk ? compare.usual : null,
        usualFrom: (n - 5).clamp(0, n - 1),
        usualTo: n - 2,
        semanticsLabel: usualOk
            ? 'Load by month. Last month ${lastDone!.load.round()}, '
                  'usual ${compare.usual.round()}. '
                  'This month so far ${now.load.round()}.'
            : 'Load by month. This month so far ${now.load.round()}.',
        bars: [
          for (final p in months)
            LoadBarData.period(
              p,
              label: _months[p.start.month - 1],
              outline: p.current ? LoadBarOutline.dashed : LoadBarOutline.none,
              tag: p.current ? 'SO FAR' : null,
            ),
        ],
      ),
      [
        if (line != null) ...[
          const SizedBox(height: Space.x16),
          Text(
            'LAST MONTH',
            style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
          ),
          const SizedBox(height: Space.x4),
          Text(
            line,
            key: const ValueKey('load-month-line'),
            style: RunSoloType.body17.copyWith(color: t.inkPrimary),
          ),
        ],
      ],
    );
  }

  (List<(String, String)>, Widget, List<Widget>) _year(
    engine.YearLoad y,
    RunSoloTokens t,
  ) {
    final line = engine.LoadWords.yearLine(y);
    return (
      [
        (_kmLabel, _km(y.km)),
        ('RUNS', '${y.runs}'),
        ('TIME', _time(y.minutes)),
      ],
      LoadBars(
        key: const ValueKey('load-bars'),
        semanticsLabel: 'Load by month this year. ${y.runs} runs.',
        bars: [
          for (final p in y.months)
            LoadBarData.period(
              p,
              label: _months[p.start.month - 1].substring(0, 1),
              outline: p.current ? LoadBarOutline.dashed : LoadBarOutline.none,
            ),
        ],
      ),
      [
        if (line != null) ...[
          const SizedBox(height: Space.x16),
          Text(
            line,
            key: const ValueKey('load-year-line'),
            style: RunSoloType.body17.copyWith(color: t.inkPrimary),
          ),
        ],
      ],
    );
  }
}
