import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../../state/progress_snapshot.dart';
import '../../theme/lanes.dart';
import '../../theme/theme.dart';
import 'lane_block.dart';

/// The weekly streak with its freeze, and the firsts so far. One run in a
/// Monday-to-Sunday week keeps the streak alive; a freeze covers a missed
/// week. Eight dots: ran (filled), missed (hollow), frozen (ice).
class StreakCard extends StatelessWidget {
  const StreakCard({
    super.key,
    required this.streak,
    required this.firstsDone,
    required this.firstsTotal,
  });

  final WeeklyStreak streak;
  final int firstsDone;
  final int firstsTotal;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final weeks = streak.weeks;
    final title = weeks == 0
        ? 'START YOUR STREAK'
        : weeks == 1
        ? '1 WEEK STREAK'
        : '$weeks WEEK STREAK';
    final line = weeks == 0
        ? 'Run once this week and it starts. Miss a week and a freeze covers it.'
        : streak.thisWeekDone
        ? 'This week is done. Rest up.'
        : 'Run once before Sunday to keep it going.';
    final freeze = streak.freezesReady == 0
        ? 'No freeze ready'
        : streak.freezesReady == 1
        ? '1 freeze ready'
        : '${streak.freezesReady} freezes ready';
    return LaneTintCard(
      key: const ValueKey('home-streak'),
      lane: engine.IdentityLane.aerobic,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: RunSoloType.heading26.copyWith(color: t.inkPrimary),
                ),
              ),
              Text(
                freeze,
                style: RunSoloType.label13.copyWith(color: t.inkSecondary),
              ),
            ],
          ),
          const SizedBox(height: Space.x4),
          Text(line, style: RunSoloType.body15.copyWith(color: t.inkSecondary)),
          const SizedBox(height: Space.x12),
          Row(
            children: [
              for (var i = 0; i < streak.recent.length; i++) ...[
                if (i > 0) const SizedBox(width: Space.x8),
                _WeekDot(state: streak.recent[i]),
              ],
              const Spacer(),
              Text(
                '$firstsDone OF $firstsTotal FIRSTS',
                key: const ValueKey('home-firsts'),
                style: RunSoloType.micro11.copyWith(
                  color: t.inkPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WeekDot extends StatelessWidget {
  const _WeekDot({required this.state});

  /// true = ran, false = missed, null = frozen.
  final bool? state;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final ran = state == true;
    final frozen = state == null;
    final colour = frozen ? t.laneFill(engine.IdentityLane.long) : t.inkPrimary;
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: ran || frozen ? colour : Colors.transparent,
        border: Border.all(
          color: ran || frozen ? colour : t.inkMuted,
          width: 2,
        ),
      ),
      child: frozen
          ? Icon(Icons.ac_unit, size: 10, color: readableOn(colour))
          : null,
    );
  }
}
