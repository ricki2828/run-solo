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
import '../widgets/board_spark.dart';

/// The boards overview (LB3c, mockup frames 1-9): every board the runs
/// have earned, grouped Distance, parkrun, Goals, Intervals, Tests. Each
/// card is the board's best, how the last run stood against it, and the
/// spark-bars of the last 8 results. A best set in the last 14 days gets
/// the "New best" strip on top and a NEW tag on its card.
class BoardsOverview extends StatefulWidget {
  const BoardsOverview({super.key});

  @override
  State<BoardsOverview> createState() => _BoardsOverviewState();
}

class _BoardsOverviewState extends State<BoardsOverview> {
  Future<({Boards boards, List<RunSummary> runs})>? _load;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final history = AppServices.of(context).history;
    _load ??= () async {
      final boards = await history.boards();
      final runs = await history.list();
      return (boards: boards, runs: runs);
    }();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final services = AppServices.of(context);
    return FutureBuilder<({Boards boards, List<RunSummary> runs})>(
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
        final boards = data.boards;
        if (boards.isEmpty) {
          return _Empty(parkrun: kEventNames.parkrun);
        }
        final units = services.settings.settings.units;
        final now = services.now();
        final labels = CourseLabels(data.runs, services.courseNames);
        String titleOf(String key) => _titleOf(boards, labels, key);
        final sections = _sections(boards, titleOf);
        final strip = _latestBest(boards, titleOf, now);
        return ListView(
          key: const ValueKey('boards-overview'),
          padding: const EdgeInsets.fromLTRB(
            Space.screenGutter,
            Space.x8,
            Space.screenGutter,
            Space.x32,
          ),
          children: [
            if (boards.updating)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.x12),
                child: Text(
                  'Updating your boards',
                  style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                ),
              ),
            if (strip != null) ...[
              _LatestBestStrip(spot: strip, units: units),
              const SizedBox(height: Space.x24),
            ],
            for (final section in sections) ...[
              _SectionHeader(section.title),
              for (final card in section.cards) ...[
                _BoardCard(card: card, units: units, fresh: card.isFresh(now)),
                const SizedBox(height: Space.x12),
              ],
              const SizedBox(height: Space.x16),
            ],
          ],
        );
      },
    );
  }
}

/// A board's display name: the course's own label for a course board, the
/// test's name, otherwise the engine's distance / window / session title.
String _titleOf(Boards boards, CourseLabels labels, String key) {
  if (key == engine.ComparisonKey.cooper) return 'Cooper 12-min test';
  if (engine.ComparisonKey.isParkrun(key) &&
      key != engine.ComparisonKey.parkrun) {
    return labels.labelOf(
      key.substring(engine.ComparisonKey.parkrun.length + 1),
    );
  }
  return boards.titleOf(key, kEventNames);
}

/// The mockup's sections, in its order. Interval boards are anything left
/// over (session comparison keys).
enum _Section { distance, parkrun, goals, intervals, tests }

_Section _sectionOf(String key) {
  if (engine.BestEffortDistance.ofKey(key) != null) return _Section.distance;
  if (engine.ComparisonKey.isParkrun(key)) return _Section.parkrun;
  if (engine.BestTimeWindow.ofKey(key) != null ||
      engine.ComparisonKey.isGoal(key)) {
    return _Section.goals;
  }
  if (key == engine.ComparisonKey.cooper) return _Section.tests;
  return _Section.intervals;
}

/// Distance cards read the way the mockup lays them out: 5K and 10K first,
/// then the short and long boards.
const _distanceOrder = [5000, 10000, 1000, 1609, 21097, 42195];

class _CardData {
  const _CardData({
    required this.key,
    required this.title,
    required this.board,
  });
  final String key;
  final String title;
  final engine.Leaderboard board;

  static const freshWindow = Duration(days: 14);

  bool isFresh(DateTime now) {
    final pb = board.pb;
    return pb != null && !pb.date.isBefore(now.subtract(freshWindow));
  }
}

class _SectionData {
  const _SectionData(this.title, this.cards);
  final String title;
  final List<_CardData> cards;
}

List<_SectionData> _sections(Boards boards, String Function(String) titleOf) {
  final bySection = <_Section, List<_CardData>>{};
  for (final e in boards.byKey.entries) {
    if (e.value.length == 0) continue;
    bySection
        .putIfAbsent(_sectionOf(e.key), () => [])
        .add(_CardData(key: e.key, title: titleOf(e.key), board: e.value));
  }
  for (final cards in bySection.values) {
    cards.sort((a, b) => a.title.compareTo(b.title));
  }
  bySection[_Section.distance]?.sort((a, b) {
    final ma = engine.Leaderboards.metresOf(a.key)?.round() ?? 0;
    final mb = engine.Leaderboards.metresOf(b.key)?.round() ?? 0;
    final ia = _distanceOrder.indexOf(ma);
    final ib = _distanceOrder.indexOf(mb);
    if (ia >= 0 && ib >= 0) return ia.compareTo(ib);
    if (ia >= 0) return -1;
    if (ib >= 0) return 1;
    return ma.compareTo(mb);
  });
  return [
    for (final (section, heading) in [
      (_Section.distance, 'DISTANCE'),
      (_Section.parkrun, kEventNames.parkrun.toUpperCase()),
      (_Section.goals, 'GOALS'),
      (_Section.intervals, 'INTERVALS'),
      (_Section.tests, 'TESTS'),
    ])
      if (bySection[section]?.isNotEmpty ?? false)
        _SectionData(heading, bySection[section]!),
  ];
}

/// The newest best across every board (the mockup's "latest best" strip):
/// only a board with something to beat earns the "quicker than" line, so a
/// first entry stays a NEW tag on its card instead.
class _SpotData {
  const _SpotData(this.card, this.previous);
  final _CardData card;

  /// The best this one replaced.
  final engine.BoardRun previous;
}

_SpotData? _latestBest(
  Boards boards,
  String Function(String) titleOf,
  DateTime now,
) {
  _SpotData? found;
  for (final e in boards.byKey.entries) {
    final b = e.value;
    if (b.length < 2) continue;
    final card = _CardData(key: e.key, title: titleOf(e.key), board: b);
    if (!card.isFresh(now)) continue;
    if (found == null || b.pb!.date.isAfter(found.card.board.pb!.date)) {
      found = _SpotData(card, b.ranked[1]);
    }
  }
  return found;
}

/// "17 s", "3 s/km", "110 m", "1.0" - the gap between two results, read
/// the way the board reads its values.
String _gapText(engine.BoardKind kind, double gap, Units units) {
  return switch (kind) {
    engine.BoardKind.bestEffort ||
    engine.BoardKind.course ||
    engine.BoardKind.goalDistance => () {
      final s = gap.round();
      return s < 60 ? '$s s' : Fmt.clock(s * 1000);
    }(),
    engine.BoardKind.interval =>
      '${gap.round()} s/${units == Units.mi ? 'mi' : 'km'}',
    engine.BoardKind.distanceInTime => Fmt.distance(gap, units),
    engine.BoardKind.cooper => gap.toStringAsFixed(1),
  };
}

/// The card's big number: the board's best, read the way the board reads
/// (the VO2 estimate keeps its unit on a line of its own).
String _value(engine.Leaderboard board, double metric, Units units) =>
    switch (board.kind) {
      engine.BoardKind.cooper => metric.round().toString(),
      _ => Boards.value(board, metric, units),
    };

class _LatestBestStrip extends StatelessWidget {
  const _LatestBestStrip({required this.spot, required this.units});
  final _SpotData spot;
  final Units units;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final board = spot.card.board;
    final pb = board.pb!;
    final gap = (pb.metric - spot.previous.metric).abs();
    final how = switch (board.kind) {
      engine.BoardKind.cooper => 'up ${_gapText(board.kind, gap, units)}',
      engine.BoardKind.distanceInTime =>
        '${_gapText(board.kind, gap, units)} further',
      _ => '${_gapText(board.kind, gap, units)} quicker',
    };
    return Column(
      key: const ValueKey('boards-latest-best'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'NEW BEST · ${spot.card.title.toUpperCase()}',
          style: RunSoloType.micro11.copyWith(color: t.accentArc),
        ),
        const SizedBox(height: Space.x4),
        Text(
          _value(board, pb.metric, units),
          style: RunSoloType.display44.copyWith(color: t.inkPrimary),
        ),
        Text(
          '${Fmt.dayDate(pb.date)} · $how than ${Fmt.dayDate(spot.previous.date)}',
          style: RunSoloType.body15.copyWith(color: t.inkSecondary),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.x8),
      child: Text(
        title,
        style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
      ),
    );
  }
}

class _BoardCard extends StatelessWidget {
  const _BoardCard({
    required this.card,
    required this.units,
    required this.fresh,
  });
  final _CardData card;
  final Units units;
  final bool fresh;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final board = card.board;
    final pb = board.pb!;
    final byDate = [...board.ranked]..sort((a, b) => a.date.compareTo(b.date));
    final last = byDate.last;
    final rank = board.rankOf(last.runId)!;
    final n = board.length;
    final higher =
        board.kind == engine.BoardKind.cooper ||
        board.kind == engine.BoardKind.distanceInTime;
    final gap = (last.metric - pb.metric).abs();
    final sub = n == 1
        ? '1 run · the next one races it'
        : rank == 1
        ? '$n runs · last was your best'
        : '$n runs · last #$rank, ${_gapText(board.kind, gap, units)} off';
    final spark = byDate.length > 8
        ? byDate.sublist(byDate.length - 8)
        : byDate;
    return Container(
      key: ValueKey('board-card-${card.key}'),
      padding: const EdgeInsets.all(Space.x16),
      decoration: BoxDecoration(
        color: t.bgRaised,
        borderRadius: BorderRadius.circular(Radii.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  card.title,
                  style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                ),
              ),
              if (fresh) _Tag(text: 'NEW', color: t.accentArc),
              if (pb.official) ...[
                const SizedBox(width: Space.x8),
                _Tag(text: 'official', color: t.inkSecondary),
              ],
            ],
          ),
          const SizedBox(height: Space.x4),
          Text(
            _value(board, pb.metric, units),
            style: RunSoloType.display44.copyWith(color: t.inkPrimary),
          ),
          if (board.kind == engine.BoardKind.cooper)
            Text(
              'VO2 estimate',
              style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
            ),
          const SizedBox(height: Space.x4),
          Text(sub, style: RunSoloType.body15.copyWith(color: t.inkSecondary)),
          const SizedBox(height: Space.x12),
          BoardSpark(
            values: [for (final r in spark) r.metric],
            lowerBetter: !higher,
            best: pb.metric,
            bestColor: t.accentArc,
            newestColor: t.inkPrimary,
            barColor: t.inkMuted,
          ),
        ],
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

class _Empty extends StatelessWidget {
  const _Empty({required this.parkrun});
  final String parkrun;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.x32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Nothing to rank yet',
              style: RunSoloType.title28.copyWith(color: t.inkPrimary),
            ),
            const SizedBox(height: Space.x12),
            Text(
              'Your boards build themselves. Finish a run - a $parkrun, '
              'a 5K effort, intervals, a 12-minute test - and the first '
              'one lands here.',
              textAlign: TextAlign.center,
              style: RunSoloType.body15.copyWith(color: t.inkSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
