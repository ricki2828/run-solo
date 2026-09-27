import 'dart:math' as math;

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
import '../widgets/weather_chip.dart';
import 'run_detail_screen.dart';

/// The board detail (LB3d, mockup frames 2-8, design addendum A11.3-5):
/// one board's hero best, trend in words, podium, the recent-runs bar
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
  bool _heatOn = false;
  bool _heatTouched = false;
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
    _heatOn = services.settings.settings.compareHeatAdjusted;
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
              heatOn: _heatTouched
                  ? _heatOn
                  : services.settings.settings.compareHeatAdjusted,
              selected: _selected,
              onSelect: (i) => setState(() => _selected = i),
              onToggleHeat: () => setState(() {
                _heatTouched = true;
                _heatOn = !_heatOn;
              }),
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
    required this.hasHeatTwin,
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

  /// Goal boards carry no heat twin (#81): their heat column stays a dash.
  final bool hasHeatTwin;

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
      hasHeatTwin: engine.Leaderboards.hasHeatTwin(key),
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
    required this.heatOn,
    required this.selected,
    required this.onSelect,
    required this.onToggleHeat,
  });

  final _BoardView view;
  final Boards boards;
  final Units units;
  final DateTime now;
  final AnimationController pb;
  final bool pbMoment;
  final bool heatOn;
  final int? selected;
  final ValueChanged<int?> onSelect;
  final VoidCallback onToggleHeat;

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
        const SizedBox(height: Space.x16),
        _Podium(view: view, units: units),
        const SizedBox(height: Space.x24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.screenGutter),
          child: Text(
            '${n > 10 ? 'LAST 10' : 'EVERY ${view.noun == 'tests'
                      ? 'TEST'
                      : view.noun == 'sessions'
                      ? 'SESSION'
                      : 'RUN'}'} · ${switch (view.board.kind) {
              engine.BoardKind.cooper => 'HIGHER',
              engine.BoardKind.distanceInTime => 'FURTHER',
              _ => 'FASTER',
            }} IS TALLER',
            style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
          ),
        ),
        const SizedBox(height: Space.x8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.screenGutter),
          child: _BoardChart(
            view: view,
            units: units,
            heatOn: heatOn,
            animation: pb,
            pbMoment: pbMoment,
            selected: selected,
            onSelect: onSelect,
          ),
        ),
        const SizedBox(height: Space.x8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.screenGutter),
          child: _Legend(
            heatOn: heatOn,
            hasHeatTwin:
                view.hasHeatTwin && view.board.kind != engine.BoardKind.cooper,
            onToggleHeat: onToggleHeat,
          ),
        ),
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
          heatOn: heatOn,
          selectedRunId: selected == null
              ? null
              : view.board.last10[selected!].runId,
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
        : 'Your best · ${Fmt.dayDate(pbRun.date)}';
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

/// Three columns, #2 · #1 · #3, fixed heights 64 / 88 / 48: rank, not the
/// gap. #1 takes the 3 dp Arc cap and the 6 dp Arc dot; missing places
/// stay hairline outlines.
class _Podium extends StatelessWidget {
  const _Podium({required this.view, required this.units});
  final _BoardView view;
  final Units units;

  @override
  Widget build(BuildContext context) {
    final ranked = view.board.ranked;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.screenGutter),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(child: _column(ranked.length > 1 ? ranked[1] : null, 64)),
          const SizedBox(width: Space.x8),
          Expanded(
            flex: 115,
            child: _column(ranked.isNotEmpty ? ranked[0] : null, 88),
          ),
          const SizedBox(width: Space.x8),
          Expanded(child: _column(ranked.length > 2 ? ranked[2] : null, 48)),
        ],
      ),
    );
  }

  Widget _column(engine.BoardRun? run, double height) {
    return Builder(
      builder: (context) {
        final t = Theme.of(context).extension<RunSoloTokens>()!;
        final first = run != null && view.board.rankOf(run.runId) == 1;
        return Column(
          children: [
            if (first)
              Container(
                width: 6,
                height: 6,
                margin: const EdgeInsets.only(bottom: Space.x4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: t.accentArc,
                ),
              ),
            Text(
              run == null ? '–' : view.fmt(run.metric, units),
              style:
                  (first
                          ? RunSoloType.title28.copyWith(fontSize: 34)
                          : RunSoloType.title28)
                      .copyWith(color: run == null ? t.inkMuted : t.inkPrimary),
            ),
            SizedBox(
              height: 16,
              child: run != null && !first
                  ? Text(
                      view.gap(run.metric, units),
                      style: RunSoloType.label13.copyWith(
                        color: t.inkSecondary,
                      ),
                    )
                  : null,
            ),
            Container(
              height: height,
              decoration: BoxDecoration(
                color: run == null ? null : t.bgRaised,
                border: Border.all(color: t.lineHair),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(8),
                ),
              ),
              child: Stack(
                children: [
                  if (first)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: Container(
                        height: 3,
                        decoration: BoxDecoration(
                          color: t.accentArc,
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(8),
                          ),
                        ),
                      ),
                    ),
                  Center(
                    child: run == null
                        ? null
                        : Text(
                            '${view.board.rankOf(run.runId)}',
                            style: RunSoloType.title28.copyWith(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: first ? t.inkPrimary : t.inkSecondary,
                            ),
                          ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Space.x4),
            Text(
              run == null ? '' : _DetailBody._shortDate(run.date).toUpperCase(),
              style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
            ),
          ],
        );
      },
    );
  }
}

/// The recent-runs chart (A11.3.5): the last 10, oldest left. Taller is
/// always better; the axis is cropped past the worst and says where it
/// starts; the Best line sits at the PB's height even when the PB is
/// older than the shown runs.
class _BoardChart extends StatelessWidget {
  const _BoardChart({
    required this.view,
    required this.units,
    required this.heatOn,
    required this.animation,
    required this.pbMoment,
    required this.selected,
    required this.onSelect,
  });

  final _BoardView view;
  final Units units;
  final bool heatOn;
  final AnimationController animation;
  final bool pbMoment;
  final int? selected;
  final ValueChanged<int?> onSelect;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final shown = view.board.last10;
    final one = shown.length == 1;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: one
          ? null
          : (d) {
              final hit = _ChartPainter.slotAt(
                d.localPosition.dx,
                size: _ChartPainter.plotSize(context),
                count: shown.length,
              );
              onSelect(hit == selected ? null : hit);
            },
      child: SizedBox(
        key: const ValueKey('board-chart'),
        height: _ChartPainter.kHeight,
        width: double.infinity,
        child: AnimatedBuilder(
          animation: animation,
          builder: (context, _) => CustomPaint(
            painter: _ChartPainter(
              view: view,
              units: units,
              tokens: t,
              heatOn: heatOn,
              growT: pbMoment
                  ? const Interval(
                      0,
                      0.625,
                      curve: MotionCurves.emphasized,
                    ).transform(animation.value)
                  : 1,
              moveT: pbMoment
                  ? const Interval(
                      0.625,
                      1,
                      curve: MotionCurves.standard,
                    ).transform(animation.value)
                  : 1,
              pbMoment: pbMoment,
              selected: selected,
            ),
          ),
        ),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.view,
    required this.units,
    required this.tokens,
    required this.heatOn,
    required this.growT,
    required this.moveT,
    required this.pbMoment,
    required this.selected,
  });

  final _BoardView view;
  final Units units;
  final RunSoloTokens tokens;
  final bool heatOn;

  /// The new PB bar's grow progress (A11.4), 1 outside the moment.
  final double growT;

  /// The Best line's move progress from the old best to the new.
  final double moveT;
  final bool pbMoment;
  final int? selected;

  static const double kHeight = 222;
  static const double _gutter = 60;
  static const double _top = 32;
  static const double _bottom = 54;
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

  /// The mockup's chart is 320 dp wide (a 360 screen less the gutters).
  static Size plotSize(BuildContext context) {
    final w = MediaQuery.of(context).size.width - Space.screenGutter * 2;
    return Size(w, kHeight);
  }

  static int? slotAt(double dx, {required Size size, required int count}) {
    final plotW = size.width - _gutter;
    final slot = plotW / math.max(count, 10);
    final x0 = plotW - count * slot;
    if (dx < x0 || dx > plotW) return null;
    final i = ((dx - x0) / slot).floor();
    return i >= 0 && i < count ? i : null;
  }

  /// Goodness scale (mockup `scale`): faster/further is up. The baseline
  /// crops 10% of the shown range past the worst, rounded outward, so
  /// seconds show; the best stops 6% short of the top.
  _Scale _scale(List<double> vals, double plotBottom) {
    final lower = view.lower;
    final best = lower ? vals.reduce(math.min) : vals.reduce(math.max);
    final worst = lower ? vals.reduce(math.max) : vals.reduce(math.min);
    var span = (worst - best).abs();
    if (span == 0) span = (best * 0.02).abs();
    if (span == 0) span = 1;
    var base = lower ? worst + span * 0.1 : worst - span * 0.1;
    final r = view.roundTo;
    base = lower ? (base / r).ceil() * r : (base / r).floor() * r;
    final top = lower ? best - span * 0.06 : best + span * 0.06;
    double y(double v) =>
        plotBottom -
        (plotBottom - _top) *
            ((lower ? base - v : v - base) / (lower ? base - top : top - base));
    return _Scale(y: y, base: base, top: top);
  }

  void _text(
    Canvas canvas,
    String s,
    Offset at, {
    required Color color,
    double size = 11,
    bool alignEnd = false,
    bool alignCenter = false,
    FontWeight weight = FontWeight.w500,
    double letterSpacing = 0,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          fontFamily: RunSoloType.ui,
          fontSize: size,
          fontWeight: weight,
          color: color,
          letterSpacing: letterSpacing,
          fontFeatures: RunSoloType.tabular,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = alignEnd
        ? at.dx - tp.width
        : alignCenter
        ? at.dx - tp.width / 2
        : at.dx;
    tp.paint(canvas, Offset(dx, at.dy - tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final board = view.board;
    final shown = board.last10;
    if (shown.isEmpty) return;
    final pbRun = board.pb!;
    final plotW = size.width - _gutter;
    final plotBottom = kHeight - _bottom;
    final one = shown.length == 1;
    final slot = plotW / math.max(shown.length, 10);
    final bw = math.min(20.0, slot * 0.62);
    final x0 = plotW - shown.length * slot;

    // The scale includes the heat ticks and the PB, so nothing clips.
    final vals = <double>[
      for (final e in shown) ...[
        view.board.rankValue(e),
        if (heatOn &&
            view.board.kind != engine.BoardKind.cooper &&
            e.adjMetric != null)
          e.adjMetric!,
      ],
      view.board.rankValue(pbRun),
    ];
    final sc = one ? null : _scale(vals, plotBottom);
    double yOf(double v) => one ? _top + (plotBottom - _top) * 0.3 : sc!.y(v);
    final bestY = yOf(view.board.rankValue(pbRun));

    // Gridlines and right-hand labels on round steps; the crop note.
    if (!one && sc != null) {
      final lo = math.min(sc.base, sc.top);
      final hi = math.max(sc.base, sc.top);
      final step = view.steps.firstWhere(
        (st) => (hi - lo) / st <= 3.2,
        orElse: () => view.steps.last,
      );
      final grid = Paint()
        ..color = tokens.lineHair
        ..strokeWidth = 1;
      var v = (lo / step).ceil() * step;
      for (; v <= hi; v += step) {
        final yy = sc.y(v);
        if ((yy - bestY).abs() < 12 || yy > plotBottom - 4) continue;
        canvas.drawLine(Offset(0, yy), Offset(plotW, yy), grid);
        _text(
          canvas,
          view.tick(v, units),
          Offset(plotW + 6, yy),
          color: tokens.inkMuted,
        );
      }
      _text(
        canvas,
        'Axis starts at ${view.tick(sc.base, units)}${view.axisUnit(units)}',
        Offset(plotW, kHeight - 8),
        color: tokens.inkSecondary,
        alignEnd: true,
      );
    }
    canvas.drawLine(
      Offset(0, plotBottom),
      Offset(plotW, plotBottom),
      Paint()
        ..color = tokens.inkMuted
        ..strokeWidth = 1,
    );

    // Bars: the PB is Arc, the newest Bone, the rest muted. In the PB
    // moment the new bar grows up from the baseline.
    var prevMonth = -1;
    var lastMonthX = -99.0;
    for (var i = 0; i < shown.length; i++) {
      final e = shown[i];
      final x = x0 + i * slot + (slot - bw) / 2;
      final isPb = e.runId == pbRun.runId && e.metric == pbRun.metric;
      final newest = i == shown.length - 1;
      final y = yOf(e.metric);
      final top = isPb ? plotBottom - (plotBottom - y) * growT : y;
      final fill = isPb
          ? tokens.accentArc
          : newest
          ? tokens.inkPrimary
          : tokens.inkMuted;
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTRB(x, top, x + bw, plotBottom),
          topLeft: const Radius.circular(3),
          topRight: const Radius.circular(3),
        ),
        Paint()..color = fill,
      );
      if (heatOn && !one && view.board.kind != engine.BoardKind.cooper) {
        final adj = e.adjMetric;
        if (adj != null) {
          final ty = sc!.y(adj);
          canvas.drawLine(
            Offset(x - 3, ty),
            Offset(x + bw + 3, ty),
            Paint()
              ..color = tokens.inkSecondary
              ..strokeWidth = 2,
          );
        } else {
          canvas.drawCircle(
            Offset(x + bw / 2, y - 9),
            2.5,
            Paint()
              ..color = tokens.inkMuted
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.2,
          );
        }
      }
      if (selected == i) {
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTRB(x - 2, y - 2, x + bw + 2, plotBottom),
            topLeft: const Radius.circular(3),
            topRight: const Radius.circular(3),
          ),
          Paint()
            ..color = tokens.inkPrimary
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
      _text(
        canvas,
        '${e.date.day}',
        Offset(x + bw / 2, plotBottom + 14),
        color: tokens.inkSecondary,
        alignCenter: true,
      );
      if (e.date.month != prevMonth && x - lastMonthX >= 30) {
        lastMonthX = x;
        _text(
          canvas,
          _months[e.date.month - 1].toUpperCase(),
          Offset(x + bw / 2, plotBottom + 27),
          color: tokens.inkMuted,
          size: 10,
          alignCenter: true,
          letterSpacing: 0.8,
        );
      }
      prevMonth = e.date.month;
    }

    // The Best line. In the PB moment it moves up from the old best,
    // which stays behind as a ghost ("was 51:10").
    double lineY = bestY;
    if (pbMoment && board.length >= 2) {
      final oldY = yOf(board.ranked[1].metric);
      lineY = oldY + (bestY - oldY) * moveT;
      if (moveT < 1) {
        final ghost = Paint()
          ..color = tokens.inkMuted.withValues(alpha: 0.45)
          ..strokeWidth = 1;
        _dashed(canvas, Offset(0, oldY), Offset(plotW, oldY), ghost);
        _text(
          canvas,
          'was ${view.tick(board.ranked[1].metric, units)}',
          Offset(plotW + 6, oldY),
          color: tokens.inkMuted,
        );
      }
    }
    final bestPaint = Paint()
      ..color = tokens.inkSecondary
      ..strokeWidth = 1;
    _dashed(canvas, Offset(0, lineY), Offset(plotW, lineY), bestPaint);
    _text(
      canvas,
      'Best',
      Offset(plotW + 6, lineY - 6),
      color: tokens.inkPrimary,
    );
    _text(
      canvas,
      view.tick(pbRun.metric, units),
      Offset(plotW + 6, lineY + 7),
      color: tokens.inkSecondary,
    );

    // The tap callout: "Sat 20 Sep · 24:05 · 17 s off your best".
    final sel = selected;
    if (sel != null && sel < shown.length) {
      final e = shown[sel];
      final gapText = e.runId == pbRun.runId && e.metric == pbRun.metric
          ? 'your best'
          : '${view.gap(e.metric, units).replaceFirst('+', '')} off your best';
      final label =
          '${Fmt.dayDate(e.date)} · ${view.fmt(e.metric, units)} · $gapText';
      const bw2 = 250.0;
      final cx = x0 + sel * slot + slot / 2;
      final bx = (cx - bw2 / 2).clamp(0.0, size.width - bw2);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(bx, 0, bw2, 24),
          const Radius.circular(8),
        ),
        Paint()..color = tokens.bgRaised,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(bx, 0, bw2, 24),
          const Radius.circular(8),
        ),
        Paint()
          ..color = tokens.lineHair
          ..style = PaintingStyle.stroke,
      );
      _text(
        canvas,
        label,
        Offset(bx + bw2 / 2, 12),
        color: tokens.inkPrimary,
        size: 12,
        alignCenter: true,
      );
    }
  }

  void _dashed(Canvas canvas, Offset a, Offset b, Paint paint) {
    const dash = 3.0, gap = 4.0;
    var x = a.dx;
    while (x < b.dx) {
      canvas.drawLine(
        Offset(x, a.dy),
        Offset(math.min(x + dash, b.dx), b.dy),
        paint,
      );
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      old.growT != growT ||
      old.moveT != moveT ||
      old.selected != selected ||
      old.heatOn != heatOn ||
      old.pbMoment != pbMoment;
}

class _Scale {
  const _Scale({required this.y, required this.base, required this.top});
  final double Function(double) y;
  final double base;
  final double top;
}

/// The chart legend: your best / newest / best, plus the heat-adjusted
/// tick and no-weather ring when the heat layer shows. Tapping it toggles
/// that layer (A11.3.5).
class _Legend extends StatelessWidget {
  const _Legend({
    required this.heatOn,
    required this.hasHeatTwin,
    required this.onToggleHeat,
  });
  final bool heatOn;
  final bool hasHeatTwin;
  final VoidCallback onToggleHeat;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return InkWell(
      key: const ValueKey('board-legend'),
      onTap: hasHeatTwin ? onToggleHeat : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.x4),
        child: Wrap(
          spacing: Space.x16,
          runSpacing: Space.x4,
          children: [
            _item(_Swatch(fill: t.accentArc), 'your best', t),
            _item(_Swatch(fill: t.inkPrimary), 'newest', t),
            _item(_Swatch(dashed: t.inkSecondary), 'best', t),
            if (heatOn && hasHeatTwin) ...[
              _item(_Swatch(tick: t.inkSecondary), 'heat-adjusted estimate', t),
              _item(_Swatch(ring: t.inkMuted), 'no weather', t),
            ],
          ],
        ),
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
  const _Swatch({this.fill, this.dashed, this.tick, this.ring});
  final Color? fill;
  final Color? dashed;
  final Color? tick;
  final Color? ring;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 16,
      height: 12,
      child: CustomPaint(
        painter: _SwatchPainter(
          fill: fill,
          dashed: dashed,
          tick: tick,
          ring: ring,
        ),
      ),
    );
  }
}

class _SwatchPainter extends CustomPainter {
  _SwatchPainter({this.fill, this.dashed, this.tick, this.ring});
  final Color? fill;
  final Color? dashed;
  final Color? tick;
  final Color? ring;

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
    if (ring != null) {
      canvas.drawCircle(
        Offset(6, size.height / 2),
        2.5,
        Paint()
          ..color = ring!
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }
  }

  @override
  bool shouldRepaint(_SwatchPainter old) =>
      old.fill != fill ||
      old.dashed != dashed ||
      old.tick != tick ||
      old.ring != ring;
}

/// The ALL table (A11.3.7): # · value · gap · date · heat-adj, tabular.
/// #1 carries the 6 dp Arc dot; an official course time carries its tag;
/// a run with no weather says so, never a dash that reads as zero. A row
/// opens its run; the header's (i) opens the heat sheet (A6).
class _AllTable extends StatelessWidget {
  const _AllTable({
    required this.view,
    required this.units,
    required this.heatOn,
    required this.selectedRunId,
    required this.shortDate,
  });

  final _BoardView view;
  final Units units;
  final bool heatOn;
  final String? selectedRunId;
  final String Function(DateTime) shortDate;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final board = view.board;
    final valueHeader = switch (board.kind) {
      engine.BoardKind.cooper => 'VO2',
      engine.BoardKind.distanceInTime => units == Units.mi ? 'MI' : 'KM',
      engine.BoardKind.interval => 'PACE',
      _ => 'TIME',
    };
    final heatHeader = board.kind == engine.BoardKind.cooper
        ? 'HEAT-ADJ EST.'
        : 'HEAT-ADJ';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.screenGutter),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: Space.x4),
            child: Row(
              children: [
                SizedBox(width: 22, child: Text('#', style: _head(t))),
                SizedBox(width: 58, child: Text(valueHeader, style: _head(t))),
                SizedBox(width: 50, child: Text('GAP', style: _head(t))),
                Expanded(child: Text('DATE', style: _head(t))),
                InkWell(
                  key: const ValueKey('board-heat-info'),
                  onTap: () => showHeatInfoSheet(
                    context,
                    cooper: board.kind == engine.BoardKind.cooper,
                  ),
                  child: SizedBox(
                    width: 76,
                    child: Text(
                      '$heatHeader (i)',
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
        color: selected ? const Color(0x0AFFFFFF) : null,
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
              width: 58,
              child: Text(
                view.fmt(view.board.rankValue(r), units),
                style: RunSoloType.label13.copyWith(
                  fontSize: 14,
                  color: t.inkPrimary,
                ),
              ),
            ),
            SizedBox(
              width: 50,
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
              child: !view.hasHeatTwin
                  ? Text(
                      '–',
                      style: RunSoloType.label13.copyWith(
                        fontSize: 14,
                        color: t.inkMuted,
                      ),
                      textAlign: TextAlign.right,
                    )
                  : r.adjMetric == null
                  ? Align(
                      alignment: Alignment.centerRight,
                      child: _Tag(text: 'no weather', color: t.inkSecondary),
                    )
                  : Text(
                      '${view.fmt(view.board.kind == engine.BoardKind.cooper ? r.metric : r.adjMetric!, units)}${i == 0 ? ' est.' : ''}',
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
