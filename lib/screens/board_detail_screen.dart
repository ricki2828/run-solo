import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/event_names.dart';
import '../app/format.dart';
import '../app/services.dart';
import '../platform/gateway.dart';
import '../state/boards.dart';
import '../state/courses.dart';
import '../state/history_store.dart';
import '../theme/theme.dart';
import '../widgets/delta_glyph.dart';
import '../widgets/recent_bars_chart.dart';
import '../widgets/weather_chip.dart';
import 'run_detail_screen.dart';

/// The board detail (LB3d, mockup frames 2-8, design addendum A11.3-5):
/// one board's hero best, trend in words, the recent-runs bar
/// chart (taller is always better, cropped axis) and the full table. The
/// first visit after a best replays the PB quietly (A11.4), then clears
/// the board's NEW tag.
/// A10.3: a rank or PB chip (or an overview card) opens that board's
/// detail; back returns to the screen that opened it.
void openBoardDetail(BuildContext context, String boardKey) {
  Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => BoardDetailScreen(boardKey: boardKey)),
  );
}

class BoardDetailScreen extends StatefulWidget {
  const BoardDetailScreen({super.key, required this.boardKey});

  final String boardKey;

  @override
  State<BoardDetailScreen> createState() => _BoardDetailScreenState();
}

class _BoardDetailScreenState extends State<BoardDetailScreen>
    with SingleTickerProviderStateMixin {
  Future<({Boards boards, List<RunSummary> runs})>? _load;
  late final AnimationController _pb;

  /// The seen-PB check runs once, against the settings as they were when
  /// the screen opened; marking seen after the replay must not restart it.
  bool _seenChecked = false;
  bool _pbMoment = false;
  int? _selected;

  @override
  void initState() {
    super.initState();
    _pb = AnimationController(
      vsync: this,
      duration: const Duration(
        milliseconds: 640,
      ), // A11.4: 400 ms grow, then 240 ms move.
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final services = AppServices.of(context);
    final history = services.history;
    _load ??= () async {
      final boards = await history.boards();
      final runs = await history.list();
      return (boards: boards, runs: runs);
    }();
  }

  @override
  void dispose() {
    _pb.dispose();
    super.dispose();
  }

  /// A11.6's "PB seen": the runner has opened the board at its current
  /// best, so the overview's NEW tag clears.
  void _markSeen(engine.BoardRun pb) {
    final settings = AppServices.of(context).settings;
    if (settings.settings.pbSeen[widget.boardKey] == pb.runId) return;
    settings.update(
      (s) => s.copyWith(pbSeen: {...s.pbSeen, widget.boardKey: pb.runId}),
    );
  }

  /// Decides, once per opening, whether this visit replays the PB
  /// (A11.4). Runs inside the first build so the hero never flashes the
  /// new value before the roll: [_pbMoment] is set before the body reads
  /// it, and the seen mark lands when the replay ends (A11.6).
  void _checkPbMoment(engine.Leaderboard board) {
    if (_seenChecked) return;
    _seenChecked = true;
    final pb = board.pb;
    if (pb == null) return;
    final settings = AppServices.of(context).settings.settings;
    if (settings.pbSeen[widget.boardKey] == pb.runId) return;
    final reduced =
        settings.reducedMotion || MediaQuery.disableAnimationsOf(context);
    if (board.length < 2 || reduced) {
      // No replay: the end state shows straight away (A11.4).
      _pb.value = 1;
      WidgetsBinding.instance.addPostFrameCallback((_) => _markSeen(pb));
      return;
    }
    _pbMoment = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _pb.forward().whenComplete(() => _markSeen(pb));
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final services = AppServices.of(context);
    return Scaffold(
      backgroundColor: t.bgBase,
      body: SafeArea(
        child: FutureBuilder<({Boards boards, List<RunSummary> runs})>(
          future: _load,
          builder: (context, snap) {
            final data = snap.data;
            if (data == null) {
              return Center(
                child: Text(
                  'Checking your boards',
                  style: RunSoloType.body15.copyWith(color: t.inkSecondary),
                ),
              );
            }
            final board = data.boards.byKey[widget.boardKey];
            if (board == null || board.pb == null) {
              return Center(
                child: Text(
                  'This board has no entries yet',
                  style: RunSoloType.body15.copyWith(color: t.inkSecondary),
                ),
              );
            }
            final units = services.settings.settings.units;
            final labels = CourseLabels(data.runs, services.courseNames);
            final view = _BoardView.of(
              widget.boardKey,
              board,
              data.boards,
              labels,
              units,
            );
            _checkPbMoment(board);
            return _DetailBody(
              view: view,
              boards: data.boards,
              units: units,
              now: services.now(),
              pb: _pb,
              pbMoment: _pbMoment,
              selected: _selected,
              onSelect: (i) => setState(() => _selected = i),
            );
          },
        ),
      ),
    );
  }
}

/// One board's display facts, resolved once from the key: the title, the
/// count noun, and how its metric formats, rounds and reads ("faster is
/// taller" vs "further is taller").
class _BoardView {
  const _BoardView({
    required this.key,
    required this.board,
    required this.title,
    required this.noun,
    required this.lower,
    required this.roundTo,
    required this.steps,
  });

  final String key;
  final engine.Leaderboard board;
  final String title;

  /// "runs" / "tests" / "sessions", for the header count.
  final String noun;

  /// Time and pace boards: lower is better (the chart inverts its axis).
  final bool lower;

  /// The cropped baseline rounds outward to this (15 s, 5 s/km, 100 m, 1).
  final double roundTo;

  /// Axis step candidates; the first with at most ~3 gaps wins.
  final List<double> steps;

  static _BoardView of(
    String key,
    engine.Leaderboard board,
    Boards boards,
    CourseLabels labels,
    Units units,
  ) {
    final String title;
    final String noun;
    if (key == engine.ComparisonKey.cooper) {
      title = '12-min test';
      noun = 'tests';
    } else if (engine.ComparisonKey.isParkrun(key) &&
        key != engine.ComparisonKey.parkrun) {
      title = labels.labelOf(
        key.substring(engine.ComparisonKey.parkrun.length + 1),
      );
      noun = 'runs';
    } else {
      title = boards.titleOf(key, kEventNames);
      noun = switch (board.kind) {
        engine.BoardKind.interval => 'sessions',
        _ => 'runs',
      };
    }
    final (roundTo, steps) = switch (board.kind) {
      engine.BoardKind.interval => (5.0, const [5.0, 10.0, 30.0]),
      engine.BoardKind.distanceInTime => (100.0, const [100.0, 200.0, 500.0]),
      engine.BoardKind.cooper => (1.0, const [1.0, 2.0]),
      _ => (15.0, const [30.0, 60.0, 120.0]),
    };
    return _BoardView(
      key: key,
      board: board,
      title: title,
      noun: noun,
      lower:
          board.kind != engine.BoardKind.cooper &&
          board.kind != engine.BoardKind.distanceInTime,
      roundTo: roundTo,
      steps: steps,
    );
  }

  /// The value as the board reads it (time, pace, distance, VO2 number).
  String fmt(double metric, Units units) => switch (board.kind) {
    engine.BoardKind.cooper => metric.round().toString(),
    _ => Boards.value(board, metric, units),
  };

  /// The short chart-axis tick: "24:30", "4:35", "5.80", "46".
  String tick(double metric, Units units) => switch (board.kind) {
    engine.BoardKind.bestEffort ||
    engine.BoardKind.course ||
    engine.BoardKind.goalDistance => Fmt.clock((metric * 1000).round()),
    engine.BoardKind.interval => Fmt.clock((metric * 1000).round()),
    engine.BoardKind.distanceInTime => Fmt.distanceBare(metric, units),
    engine.BoardKind.cooper => metric.round().toString(),
  };

  String axisUnit(Units units) => switch (board.kind) {
    engine.BoardKind.distanceInTime => units == Units.mi ? ' mi' : ' km',
    engine.BoardKind.cooper => '',
    _ => '',
  };

  /// "+17 s", "+1:18", "+3 s/km", "+110 m", "+0.8" - the gap to the best.
  String gap(double metric, Units units) {
    final best = board.rankValue(board.pb!);
    final g = switch (board.kind) {
      engine.BoardKind.cooper => best - metric,
      engine.BoardKind.distanceInTime => best - metric,
      _ => metric - best,
    };
    if (g <= 0) return '–';
    return switch (board.kind) {
      engine.BoardKind.bestEffort ||
      engine.BoardKind.course ||
      engine.BoardKind.goalDistance =>
        g.round() < 60 ? '+${g.round()} s' : '+${Fmt.clock(g.round() * 1000)}',
      engine.BoardKind.interval =>
        '+${g.round()} s/${units == Units.mi ? 'mi' : 'km'}',
      engine.BoardKind.distanceInTime => '+${Fmt.distance(g, units)}',
      engine.BoardKind.cooper => '+${g.toStringAsFixed(1)}',
    };
  }
}

class _DetailBody extends StatelessWidget {
  const _DetailBody({
    required this.view,
    required this.boards,
    required this.units,
    required this.now,
    required this.pb,
    required this.pbMoment,
    required this.selected,
    required this.onSelect,
  });

  final _BoardView view;
  final Boards boards;
  final Units units;
  final DateTime now;
  final AnimationController pb;
  final bool pbMoment;
  final int? selected;
  final ValueChanged<int?> onSelect;

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  static String _shortDate(DateTime d) => '${d.day} ${_months[d.month - 1]}';

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final board = view.board;
    final n = board.length;
    final one = n == 1;
    final oldBest = pbMoment && n >= 2 ? board.ranked[1] : null;
    return ListView(
      key: const ValueKey('board-detail'),
      padding: const EdgeInsets.only(bottom: Space.x32),
      children: [
        _LanesHeader(title: view.title, count: n, noun: view.noun),
        _Hero(
          view: view,
          boards: boards,
          units: units,
          one: one,
          animation: pb,
          oldBest: oldBest,
        ),
        if (oldBest != null) _GainLine(view: view, old: oldBest, units: units),
        _TrendLine(view: view, units: units, now: now),
        const SizedBox(height: Space.x24),
        if (n < 2)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.screenGutter),
            child: ChartEmptyState(
              key: const ValueKey('board-chart-empty'),
              title: 'Two ${view.noun} draw the first chart.',
              body: n == 1 ? 'One so far. The next one lands beside it.' : null,
            ),
          )
        else ...[
          const SizedBox(height: Space.x8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.screenGutter),
            child: _BoardChart(
              view: view,
              units: units,
              animation: pb,
              pbMoment: pbMoment,
              selected: selected,
              onSelect: onSelect,
            ),
          ),
          const SizedBox(height: Space.x8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.screenGutter),
            child: const _Legend(),
          ),
        ],
        const SizedBox(height: Space.x24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.screenGutter),
          child: Text(
            'ALL',
            style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
          ),
        ),
        const SizedBox(height: Space.x4),
        _AllTable(
          view: view,
          units: units,
          selectedRunId: selected == null
              ? null
              : _BoardChart.shownRuns(view.board)[selected!].runId,
          shortDate: _shortDate,
        ),
      ],
    );
  }
}

/// "← 5K · 12 RUNS" on lane lines (§2.2), 20 pt Barlow 700 uppercase.
class _LanesHeader extends StatelessWidget {
  const _LanesHeader({
    required this.title,
    required this.count,
    required this.noun,
  });
  final String title;
  final int count;
  final String noun;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return CustomPaint(
      painter: _LanesPainter(color: t.lineHair),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Space.x8,
          Space.x12,
          Space.screenGutter,
          Space.x16,
        ),
        child: Row(
          children: [
            IconButton(
              key: const ValueKey('board-detail-back'),
              icon: Icon(Icons.arrow_back, color: t.inkSecondary),
              onPressed: () => Navigator.of(context).pop(),
            ),
            Expanded(
              child: Text(
                '$title · $count ${count == 1 ? noun.substring(0, noun.length - 1) : noun}'
                    .toUpperCase(),
                style: RunSoloType.title28.copyWith(
                  fontSize: 20,
                  color: t.inkPrimary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LanesPainter extends CustomPainter {
  _LanesPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (var y = 0.5; y < size.height; y += 8) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_LanesPainter old) => old.color != color;
}

/// The PB in Barlow 600, 96 - the biggest number on the screen (A8). In
/// the PB moment it rolls over from the old best as the Best line moves.
class _Hero extends StatelessWidget {
  const _Hero({
    required this.view,
    required this.boards,
    required this.units,
    required this.one,
    required this.animation,
    required this.oldBest,
  });

  final _BoardView view;
  final Boards boards;
  final Units units;
  final bool one;
  final AnimationController animation;
  final engine.BoardRun? oldBest;

  /// "From km 2.1 to 7.1 of a 7.4 km Free run": the best-effort window's
  /// own offsets (A11.6), a course's time source, the test's distance.
  String? _provenance(engine.BoardRun pbRun) {
    final src = boards.sourceOf(pbRun.runId);
    switch (view.board.kind) {
      case engine.BoardKind.bestEffort:
        final d = engine.BestEffortDistance.ofKey(view.key);
        final eff = d == null ? null : boards.inputOf(pbRun.runId)?.efforts[d];
        if (d == null || eff == null || src == null) {
          return src?.sessionName;
        }
        final start = eff.startOffsetM;
        final end = start + d.metres;
        return 'From ${Fmt.distance(start, units)} to '
            '${Fmt.distance(end, units)} of a '
            '${Fmt.distance(src.totalM, units)} '
            '${src.sessionName ?? 'run'}';
      case engine.BoardKind.course:
        return pbRun.official ? 'Official time' : 'GPS time';
      case engine.BoardKind.cooper:
        final m = src?.cooperM;
        return m == null ? null : '${Fmt.distance(m, units)} in 12 minutes';
      case engine.BoardKind.distanceInTime:
      case engine.BoardKind.goalDistance:
      case engine.BoardKind.interval:
        return src?.sessionName;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final board = view.board;
    final pbRun = board.pb!;
    final l1 = one
        ? 'Your first ${view.title} on the board · ${Fmt.dayDate(pbRun.date)}'
        : board.kind == engine.BoardKind.cooper
        ? 'Your best estimate · ${Fmt.dayDate(pbRun.date)}'
        : 'Your best true ${view.board.kind == engine.BoardKind.interval
              ? 'pace'
              : view.board.kind == engine.BoardKind.distanceInTime
              ? 'distance'
              : 'time'} · ${Fmt.dayDate(pbRun.date)}';
    final l2 = _provenance(pbRun);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Space.screenGutter,
        Space.x16,
        Space.screenGutter,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedBuilder(
            animation: animation,
            builder: (context, _) {
              final shown = oldBest == null
                  ? board.rankValue(pbRun)
                  : board.rankValue(oldBest!) +
                        (board.rankValue(pbRun) - board.rankValue(oldBest!)) *
                            const Interval(
                              0.625,
                              1,
                              curve: MotionCurves.standard,
                            ).transform(animation.value);
              return Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    view.fmt(shown, units),
                    key: const ValueKey('board-hero'),
                    style: RunSoloType.display96.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 0.9,
                      color: t.inkPrimary,
                    ),
                  ),
                  if (board.kind == engine.BoardKind.cooper) ...[
                    const SizedBox(width: Space.x4),
                    Text(
                      'VO2 est.',
                      style: RunSoloType.title28.copyWith(
                        fontSize: 36,
                        color: t.inkSecondary,
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
          const SizedBox(height: Space.x8),
          Row(
            children: [
              Flexible(
                child: Text(
                  l1,
                  style: RunSoloType.body15.copyWith(color: t.inkSecondary),
                ),
              ),
              if (pbRun.official) ...[
                const SizedBox(width: Space.x8),
                _Tag(text: 'official', color: t.inkSecondary),
              ],
            ],
          ),
          if (l2 != null) ...[
            const SizedBox(height: Space.x4),
            Text(l2, style: RunSoloType.label13.copyWith(color: t.inkMuted)),
          ],
        ],
      ),
    );
  }
}

/// "▲ 1:18 quicker than your old best", for the PB-moment visit only.
class _GainLine extends StatelessWidget {
  const _GainLine({required this.view, required this.old, required this.units});
  final _BoardView view;
  final engine.BoardRun old;
  final Units units;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final gap =
        (view.board.rankValue(view.board.pb!) - view.board.rankValue(old))
            .abs();
    final how = switch (view.board.kind) {
      engine.BoardKind.cooper =>
        'up ${gap.toStringAsFixed(1)} from your old best',
      engine.BoardKind.distanceInTime =>
        '${Fmt.distance(gap, units)} further than your old best',
      engine.BoardKind.interval =>
        '${gap.round()} s/${units == Units.mi ? 'mi' : 'km'} '
            'quicker than your old best',
      _ =>
        '${gap.round() < 60 ? '${gap.round()} s' : Fmt.clock(gap.round() * 1000)} '
            'quicker than your old best',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Space.screenGutter,
        Space.x8,
        Space.screenGutter,
        0,
      ),
      child: Row(
        children: [
          DeltaGlyph(
            direction: DeltaDirection.up,
            color: t.inkPrimary,
            size: 12,
          ),
          const SizedBox(width: Space.x8),
          Text(
            how,
            key: const ValueKey('board-gain'),
            style: RunSoloType.label13.copyWith(
              fontSize: 15,
              color: t.inkPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// "▲ 8 s/km quicker a month" (Theil-Sen), or why there is no trend.
class _TrendLine extends StatelessWidget {
  const _TrendLine({
    required this.view,
    required this.units,
    required this.now,
  });
  final _BoardView view;
  final Units units;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final board = view.board;
    final trend = board.trend(now);
    if (trend == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          Space.screenGutter,
          Space.x12,
          Space.screenGutter,
          0,
        ),
        child: Text(
          board.length == 1
              ? 'The next ${view.noun == 'tests'
                    ? 'test'
                    : view.noun == 'sessions'
                    ? 'session'
                    : view.title} races this one'
              : 'Not enough ${view.noun} yet for a trend',
          key: const ValueKey('board-trend'),
          style: RunSoloType.body15.copyWith(color: t.inkSecondary),
        ),
      );
    }
    final m = trend.perMonth;
    final DeltaDirection dir;
    final String words;
    switch (board.kind) {
      case engine.BoardKind.distanceInTime:
        if (m.abs() < 5) {
          dir = DeltaDirection.flat;
          words = 'Holding steady month on month';
        } else {
          dir = m > 0 ? DeltaDirection.up : DeltaDirection.down;
          words =
              '${Fmt.distance(m.abs(), units)} ${m > 0 ? 'further' : 'less'} a month';
        }
      case engine.BoardKind.cooper:
        if (m.abs() < 0.05) {
          dir = DeltaDirection.flat;
          words = 'Holding steady month on month';
        } else {
          dir = m > 0 ? DeltaDirection.up : DeltaDirection.down;
          words =
              '${m.abs().toStringAsFixed(1)} ${m > 0 ? 'up' : 'down'} a month';
        }
      default:
        final s = m.abs().round();
        if (s < 1) {
          dir = DeltaDirection.flat;
          words = 'Holding steady month on month';
        } else {
          // A time board's trend is pace (s/km): negative is faster.
          dir = m < 0 ? DeltaDirection.up : DeltaDirection.down;
          words =
              '$s s/${units == Units.mi ? 'mi' : 'km'} '
              '${m < 0 ? 'quicker' : 'slower'} a month';
        }
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Space.screenGutter,
        Space.x12,
        Space.screenGutter,
        0,
      ),
      child: Row(
        children: [
          DeltaGlyph(direction: dir, color: t.inkPrimary, size: 12),
          const SizedBox(width: Space.x8),
          Text(
            words,
            key: const ValueKey('board-trend'),
            style: RunSoloType.label13.copyWith(
              fontSize: 15,
              color: t.inkPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// The recent-runs chart (A11.3.5) on the shared bar style: the last 8,
/// oldest left. Taller is always better; the axis is cropped past the
/// worst and says where it starts; the Best line sits at the PB's height
/// even when the PB is older than the shown runs.
class _BoardChart extends StatelessWidget {
  const _BoardChart({
    required this.view,
    required this.units,
    required this.animation,
    required this.pbMoment,
    required this.selected,
    required this.onSelect,
  });

  final _BoardView view;
  final Units units;
  final AnimationController animation;
  final bool pbMoment;
  final int? selected;
  final ValueChanged<int?> onSelect;

  /// The runs the chart draws, oldest first; the table's selection maps
  /// through the same list.
  static List<engine.BoardRun> shownRuns(engine.Leaderboard board) {
    final last = board.last10;
    return last.length > _maxBars ? last.sublist(last.length - _maxBars) : last;
  }

  static const _maxBars = 8;

  @override
  Widget build(BuildContext context) {
    final board = view.board;
    final shown = shownRuns(board);
    final pbRun = board.pb!;
    final direction = switch (board.kind) {
      engine.BoardKind.cooper => 'Higher is taller',
      engine.BoardKind.distanceInTime => 'Further is taller',
      _ => 'Faster is taller',
    };
    return RecentBarsChart(
      chartKey: const ValueKey('board-chart'),
      points: [
        for (final e in shown)
          // The bar is the true value the board ranks; the tick is the
          // actual one, only where hills or heat moved it.
          BarPoint(
            date: e.date,
            value: board.rankValue(e),
            twin: e.adjMetric == null || e.adjMetric == e.metric
                ? null
                : e.metric,
          ),
      ],
      lowerIsBetter: view.lower,
      format: (v) => view.fmt(v, units),
      tick: (v) => view.tick(v, units),
      axisSuffix: view.axisUnit(units),
      roundTo: view.roundTo,
      steps: view.steps,
      direction: direction,
      emptyTitle: 'Two ${view.noun} draw the first chart.',
      best: view.board.rankValue(pbRun),
      bestIndex: shown.indexWhere(
        (e) => e.runId == pbRun.runId && e.metric == pbRun.metric,
      ),
      maxBars: _maxBars,
      showValues: false,
      showTwins: true,
      selected: selected,
      onSelect: onSelect,
      selectedLabel: (i) {
        final e = shown[i];
        final gap = e.runId == pbRun.runId && e.metric == pbRun.metric
            ? 'your best'
            : '${view.gap(board.rankValue(e), units).replaceFirst('+', '')} off your best';
        final actual = e.adjMetric == null || e.adjMetric == e.metric
            ? ''
            : ' (actual ${view.fmt(e.metric, units)})';
        return '${Fmt.dayDate(e.date)} · '
            '${view.fmt(board.rankValue(e), units)}$actual · $gap';
      },
      moment: pbMoment && board.length >= 2 ? animation : null,
      previousBest: pbMoment && board.length >= 2
          ? board.rankValue(board.ranked[1])
          : null,
    );
  }
}

/// The chart legend: your best / best, plus the actual-value tick (the bars
/// are true pace; the tick shows what the run really was).
class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Padding(
      key: const ValueKey('board-legend'),
      padding: const EdgeInsets.symmetric(vertical: Space.x4),
      child: Wrap(
        spacing: Space.x16,
        runSpacing: Space.x4,
        children: [
          _item(_Swatch(fill: t.accentArc), 'your best', t),
          _item(_Swatch(dashed: t.inkSecondary), 'best', t),
          _item(_Swatch(tick: t.inkSecondary), 'actual', t),
        ],
      ),
    );
  }

  Widget _item(Widget swatch, String label, RunSoloTokens t) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      swatch,
      const SizedBox(width: 6),
      Text(label, style: RunSoloType.label13.copyWith(color: t.inkSecondary)),
    ],
  );
}

class _Swatch extends StatelessWidget {
  const _Swatch({this.fill, this.dashed, this.tick});
  final Color? fill;
  final Color? dashed;
  final Color? tick;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 16,
      height: 12,
      child: CustomPaint(
        painter: _SwatchPainter(fill: fill, dashed: dashed, tick: tick),
      ),
    );
  }
}

class _SwatchPainter extends CustomPainter {
  _SwatchPainter({this.fill, this.dashed, this.tick});
  final Color? fill;
  final Color? dashed;
  final Color? tick;

  @override
  void paint(Canvas canvas, Size size) {
    if (fill != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(1, 1, 8, 11),
          const Radius.circular(1.5),
        ),
        Paint()..color = fill!,
      );
    }
    if (dashed != null) {
      final p = Paint()
        ..color = dashed!
        ..strokeWidth = 1;
      for (var x = 0.0; x < size.width; x += 6) {
        canvas.drawLine(
          Offset(x, size.height / 2),
          Offset((x + 3).clamp(0, size.width), size.height / 2),
          p,
        );
      }
    }
    if (tick != null) {
      canvas.drawLine(
        Offset(0, size.height / 2),
        Offset(14, size.height / 2),
        Paint()
          ..color = tick!
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_SwatchPainter old) =>
      old.fill != fill || old.dashed != dashed || old.tick != tick;
}

/// The ALL table (A11.3.7): # · true value · gap · date · actual, tabular.
/// #1 carries the 6 dp Arc dot; an official course time carries its tag.
/// A row opens its run; the header's (i) opens the true pace sheet.
class _AllTable extends StatelessWidget {
  const _AllTable({
    required this.view,
    required this.units,
    required this.selectedRunId,
    required this.shortDate,
  });

  final _BoardView view;
  final Units units;
  final String? selectedRunId;
  final String Function(DateTime) shortDate;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final board = view.board;
    final valueHeader = switch (board.kind) {
      engine.BoardKind.cooper => 'VO2 est.',
      engine.BoardKind.distanceInTime =>
        units == Units.mi ? 'TRUE MI' : 'TRUE KM',
      engine.BoardKind.interval => 'TRUE PACE',
      _ => 'TRUE TIME',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.screenGutter),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: Space.x4),
            child: Row(
              children: [
                SizedBox(width: 22, child: Text('#', style: _head(t))),
                SizedBox(width: 76, child: Text(valueHeader, style: _head(t))),
                SizedBox(width: 56, child: Text('BEHIND', style: _head(t))),
                Expanded(child: Text('DATE', style: _head(t))),
                InkWell(
                  key: const ValueKey('board-heat-info'),
                  onTap: () => showTruePaceInfoSheet(context),
                  child: SizedBox(
                    width: 76,
                    child: Text(
                      'ACTUAL (i)',
                      style: _head(t),
                      textAlign: TextAlign.right,
                    ),
                  ),
                ),
              ],
            ),
          ),
          for (var i = 0; i < board.ranked.length; i++)
            _row(context, t, board.ranked[i], i),
        ],
      ),
    );
  }

  TextStyle _head(RunSoloTokens t) =>
      RunSoloType.micro11.copyWith(color: t.inkSecondary);

  Widget _row(BuildContext context, RunSoloTokens t, engine.BoardRun r, int i) {
    final rank = i + 1;
    final selected = r.runId == selectedRunId;
    return InkWell(
      key: ValueKey('board-row-${r.runId}'),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => RunDetailScreen(runId: r.runId)),
      ),
      child: Container(
        color: selected ? t.bgRaised : null,
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            SizedBox(
              width: 22,
              child: rank == 1
                  ? Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: t.accentArc,
                      ),
                    )
                  : Text(
                      '$rank',
                      style: RunSoloType.label13.copyWith(
                        fontSize: 14,
                        color: t.inkSecondary,
                      ),
                    ),
            ),
            SizedBox(
              width: 76,
              child: Text(
                view.fmt(view.board.rankValue(r), units),
                style: RunSoloType.label13.copyWith(
                  fontSize: 14,
                  color: t.inkPrimary,
                ),
              ),
            ),
            SizedBox(
              width: 56,
              child: Text(
                view.gap(view.board.rankValue(r), units),
                style: RunSoloType.label13.copyWith(
                  fontSize: 13,
                  color: t.inkSecondary,
                ),
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      shortDate(r.date),
                      style: RunSoloType.label13.copyWith(
                        fontSize: 14,
                        color: t.inkSecondary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (r.official) ...[
                    const SizedBox(width: Space.x8),
                    _Tag(text: 'official', color: t.inkSecondary),
                  ],
                ],
              ),
            ),
            SizedBox(
              width: 76,
              child: Text(
                view.fmt(r.metric, units),
                style: RunSoloType.label13.copyWith(
                  fontSize: 14,
                  color: t.inkSecondary,
                ),
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: t.lineHair),
        borderRadius: BorderRadius.circular(Radii.chip),
      ),
      child: Text(
        text,
        style: RunSoloType.label13.copyWith(fontSize: 10, color: color),
      ),
    );
  }
}
