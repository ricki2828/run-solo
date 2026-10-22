import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../state/quests/quest_build.dart';
import '../state/quests/quest_store.dart';
import '../theme/lanes.dart';
import '../theme/theme.dart';
import 'home_b/lane_block.dart';
import 'recent_bars_chart.dart';

/// QUESTS on the Progress tab: the active quest (or this month's offer) and
/// the last few finished. Light and calm: one quest, one number, one chart.
/// Hidden when there is nothing to show.
class QuestsSection extends StatefulWidget {
  const QuestsSection({
    super.key,
    required this.board,
    this.onTake,
    this.onAnother,
    this.onSkip,
    this.onDrop,
  });

  final QuestBoard board;
  final VoidCallback? onTake;
  final VoidCallback? onAnother;
  final VoidCallback? onSkip;
  final VoidCallback? onDrop;

  @override
  State<QuestsSection> createState() => _QuestsSectionState();
}

class _QuestsSectionState extends State<QuestsSection> {
  bool _showHistory = false;

  @override
  Widget build(BuildContext context) {
    final b = widget.board;
    if (b.isEmpty) return const SizedBox.shrink(key: ValueKey('quests-none'));
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Column(
      key: const ValueKey('quests-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'QUESTS',
          style: RunSoloType.title28.copyWith(color: t.inkPrimary),
        ),
        const SizedBox(height: Space.x8),
        if (b.active != null)
          _ActiveQuest(board: b, onDrop: widget.onDrop)
        else if (b.offer != null)
          _OfferRow(
            def: b.offer!,
            count: b.offerCount,
            onTake: widget.onTake,
            onAnother: widget.onAnother,
            onSkip: widget.onSkip,
          ),
        if (b.history.isNotEmpty) ...[
          const SizedBox(height: Space.x8),
          _History(
            entries: b.history,
            open: _showHistory,
            onToggle: () => setState(() => _showHistory = !_showHistory),
          ),
        ],
      ],
    );
  }
}

String _daysLeft(int n) => n <= 0
    ? 'Last day'
    : n == 1
    ? '1 day left'
    : '$n days left';

/// "3 OF 5", "640 M", "72 KM": the one big number of a counter quest.
String _bigNumber(engine.QuestDef d, engine.QuestProgress p) =>
    switch (d.kind) {
      engine.QuestKind.trailVisits => '${p.value.round()} OF ${d.target}',
      engine.QuestKind.climbMonth => '${engine.Quests.fmtInt(p.value)} M',
      engine.QuestKind.distanceMonth =>
        '${p.value == p.value.roundToDouble() ? p.value.round() : p.value} KM',
      _ => d.title,
    };

class _ActiveQuest extends StatelessWidget {
  const _ActiveQuest({required this.board, this.onDrop});
  final QuestBoard board;
  final VoidCallback? onDrop;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final d = board.active!;
    final p = board.progress!;
    final counter =
        d.kind == engine.QuestKind.trailVisits ||
        d.kind == engine.QuestKind.climbMonth ||
        d.kind == engine.QuestKind.distanceMonth;
    final big = _bigNumber(d, p);
    return LaneTintCard(
      key: const ValueKey('quest-active'),
      lane: questLane(d.kind),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              big,
              key: const ValueKey('quest-big'),
              maxLines: 1,
              style: RunSoloType.display64.copyWith(color: t.inkPrimary),
            ),
          ),
          if (counter) ...[
            const SizedBox(height: Space.x4),
            Text(
              d.title,
              key: const ValueKey('quest-title'),
              style: RunSoloType.heading19.copyWith(color: t.inkPrimary),
            ),
          ],
          const SizedBox(height: Space.x4),
          Text(
            d.line,
            style: RunSoloType.body15.copyWith(color: t.inkSecondary),
          ),
          const SizedBox(height: Space.x4),
          Text(
            _daysLeft(board.daysLeft),
            key: const ValueKey('quest-days'),
            style: RunSoloType.label13.copyWith(color: t.inkSecondary),
          ),
          const SizedBox(height: Space.x12),
          if (counter)
            _SegmentBar(segments: board.segments)
          else if (d.kind == engine.QuestKind.trailBest)
            _BestChart(board: board),
          if (onDrop != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const ValueKey('quest-drop'),
                style: TextButton.styleFrom(
                  foregroundColor: t.inkSecondary,
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(48, 48),
                  alignment: Alignment.centerLeft,
                ),
                onPressed: onDrop,
                child: Text(
                  'Drop this quest',
                  style: RunSoloType.label13.copyWith(
                    color: t.inkSecondary,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One segment per contributing run in the run-type colour, then an empty
/// track for what is left.
class _SegmentBar extends StatelessWidget {
  const _SegmentBar({required this.segments});
  final List<QuestSegment> segments;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    var used = 0.0;
    for (final s in segments) {
      used += s.share;
    }
    final rest = (1 - used).clamp(0.0, 1.0);
    return Semantics(
      label: '${(used.clamp(0.0, 1.0) * 100).round()} percent done',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.chip),
        child: SizedBox(
          key: const ValueKey('quest-bar'),
          height: 20,
          child: Row(
            children: [
              for (final s in segments)
                Expanded(
                  flex: (s.share.clamp(0.0, 1.0) * 1000).round().clamp(1, 1000),
                  child: Container(
                    margin: const EdgeInsets.only(right: 2),
                    color: t.barColourFor(s.mode),
                  ),
                ),
              if (rest > 0)
                Expanded(
                  flex: (rest * 1000).round().clamp(1, 1000),
                  child: Container(color: t.lineHair),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `trail_best`: the last attempts on the trail as bars, the target as the
/// dashed Best line (the shared recent-attempts chart).
class _BestChart extends StatelessWidget {
  const _BestChart({required this.board});
  final QuestBoard board;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final d = board.active!;
    final secs = [for (final ms in board.recentMs) ms / 1000];
    final best = secs.isEmpty
        ? d.target.toDouble()
        : (secs.reduce((a, b) => a < b ? a : b) < d.target
              ? secs.reduce((a, b) => a < b ? a : b)
              : d.target.toDouble());
    return RecentBarsChart(
      chartKey: const ValueKey('quest-chart'),
      // The quest's own lane colour at full saturation, never a muddy tint.
      barColor: t.laneFill(questLane(d.kind)),
      points: [
        for (var i = 0; i < secs.length; i++)
          BarPoint(date: board.recentDates[i], value: secs[i]),
      ],
      lowerIsBetter: true,
      format: (v) => engine.Quests.fmtTime(v.round()),
      direction: 'Faster is taller',
      emptyTitle: 'Run it again',
      emptyBody: 'Two runs on the trail and the bars show up here.',
      best: best,
      roundTo: 10,
      minSpan: 30,
    );
  }
}

class _OfferRow extends StatelessWidget {
  const _OfferRow({
    required this.def,
    required this.count,
    this.onTake,
    this.onAnother,
    this.onSkip,
  });
  final engine.QuestDef def;
  final int count;
  final VoidCallback? onTake;
  final VoidCallback? onAnother;
  final VoidCallback? onSkip;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return LaneTintCard(
      key: const ValueKey('quest-offer'),
      lane: questLane(def.kind),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'This month\'s quest',
            style: RunSoloType.label13.copyWith(color: t.inkSecondary),
          ),
          const SizedBox(height: Space.x4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              def.title,
              key: const ValueKey('quest-offer-title'),
              maxLines: 1,
              style: RunSoloType.display44.copyWith(color: t.inkPrimary),
            ),
          ),
          const SizedBox(height: Space.x4),
          Text(
            def.line,
            style: RunSoloType.body15.copyWith(color: t.inkSecondary),
          ),
          const SizedBox(height: Space.x12),
          Wrap(
            spacing: Space.x8,
            runSpacing: Space.x4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton(
                key: const ValueKey('quest-take'),
                onPressed: onTake,
                child: const Text('TAKE IT'),
              ),
              if (count > 1)
                OutlinedButton(
                  key: const ValueKey('quest-another'),
                  onPressed: onAnother,
                  child: const Text('ANOTHER'),
                ),
              TextButton(
                key: const ValueKey('quest-skip'),
                style: TextButton.styleFrom(
                  foregroundColor: t.inkSecondary,
                  minimumSize: const Size(48, 48),
                ),
                onPressed: onSkip,
                child: const Text('NOT THIS MONTH'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _History extends StatelessWidget {
  const _History({
    required this.entries,
    required this.open,
    required this.onToggle,
  });
  final List<QuestHistoryEntry> entries;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Column(
      key: const ValueKey('quest-history'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: const ValueKey('quest-history-toggle'),
          onTap: onToggle,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Past quests',
                    style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                  ),
                ),
                Icon(
                  open ? Icons.expand_less : Icons.expand_more,
                  color: t.inkSecondary,
                ),
              ],
            ),
          ),
        ),
        if (open)
          for (final h in entries)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.x8),
              child: Row(
                children: [
                  Icon(
                    h.done ? Icons.check_circle : Icons.circle_outlined,
                    size: 16,
                    color: h.done ? t.accentArc : t.inkMuted,
                  ),
                  const SizedBox(width: Space.x8),
                  Expanded(
                    child: Text(
                      questHistoryLine(h),
                      style: RunSoloType.body15.copyWith(color: t.inkPrimary),
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}
