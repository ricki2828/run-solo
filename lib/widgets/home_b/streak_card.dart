import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../../state/progress_snapshot.dart';
import '../../theme/lanes.dart';
import '../../theme/theme.dart';
import 'lane_block.dart';

/// The weekly streak with its freeze, on one line (title, freeze count,
/// eight week dots). The pause button shows only when it applies. One run in a
/// Monday-to-Sunday week keeps the streak alive; a freeze covers a missed
/// week. Eight dots: ran (filled), missed (hollow), frozen (ice), paused
/// (hollow with a pause bar). A paused week (ill or sore) neither counts nor
/// breaks; the runner can pause one herself or himself, no cap.
class StreakCard extends StatelessWidget {
  const StreakCard({
    super.key,
    required this.streak,
    required this.firstsDone,
    required this.firstsTotal,
    this.lane = engine.IdentityLane.aerobic,
    this.now,
    this.onPause,
    this.onUndoPause,
    this.undoable = const {},
  });

  final WeeklyStreak streak;

  /// Firsts progress; no longer drawn on the one-line card (kept so
  /// callers need no change).
  final int firstsDone;
  final int firstsTotal;

  /// The lane the card is tinted with; aerobic (green) on Home.
  final engine.IdentityLane lane;

  /// Today, to know when "Pause this week" may show (Thursday on).
  final DateTime? now;

  /// Pauses the week [weeksBack] weeks ago (0 = this week). Null hides the
  /// button.
  final ValueChanged<int>? onPause;

  /// Lifts a pause the runner made.
  final ValueChanged<int>? onUndoPause;

  /// Which of [weeksBack] 0 and 1 are the runner's own pauses (the coach's
  /// care weeks cannot be undone here).
  final Set<int> undoable;

  /// The week the pause button would pause, or null. This week once it is
  /// Thursday with no run yet; else last week if it was missed (and no freeze
  /// covered it). Never for a runner with no streak history.
  int? get _pausable {
    final n = now;
    if (onPause == null || n == null || streak.recent.length < 2) return null;
    if (!streak.recent.contains(engine.StreakWeek.ran)) return null;
    if (!streak.thisWeekDone &&
        streak.recent.last == engine.StreakWeek.missed &&
        n.weekday >= DateTime.thursday) {
      return 0;
    }
    if (streak.recent[streak.recent.length - 2] == engine.StreakWeek.missed) {
      return 1;
    }
    return null;
  }

  /// A paused week of the runner's own that Undo can lift, this week first.
  int? get _undoable {
    if (onUndoPause == null || streak.recent.length < 2) return null;
    if (streak.recent.last == engine.StreakWeek.paused &&
        undoable.contains(0)) {
      return 0;
    }
    if (streak.recent[streak.recent.length - 2] == engine.StreakWeek.paused &&
        undoable.contains(1)) {
      return 1;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final weeks = streak.weeks;
    final title = weeks == 0
        ? 'START A STREAK'
        : weeks == 1
        ? '1 WEEK STREAK'
        : '$weeks WEEK STREAK';
    final pausedNow =
        streak.recent.isNotEmpty &&
        streak.recent.last == engine.StreakWeek.paused &&
        !streak.thisWeekDone;
    final pause = _pausable;
    final undo = pause == null ? _undoable : null;
    final freeze = streak.freezesReady == 0
        ? 'No freeze ready'
        : streak.freezesReady == 1
        ? '1 freeze ready'
        : '${streak.freezesReady} freezes ready';
    return LaneTintCard(
      key: const ValueKey('home-streak'),
      lane: lane,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            container: true,
            label: pausedNow ? '$title, paused, $freeze' : '$title, $freeze',
            child: ExcludeSemantics(
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: RunSoloType.body15.copyWith(
                              color: t.inkPrimary,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        if (streak.freezesReady > 0 && weeks > 0) ...[
                          const SizedBox(width: Space.x4),
                          Icon(
                            Icons.ac_unit,
                            size: 14,
                            color: t.laneFill(engine.IdentityLane.long),
                          ),
                          const SizedBox(width: 2),
                          Text(
                            '${streak.freezesReady}',
                            style: RunSoloType.label13.copyWith(
                              color: t.inkSecondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: Space.x8),
                  for (var i = 0; i < streak.recent.length; i++) ...[
                    if (i > 0) const SizedBox(width: 3),
                    _WeekDot(state: streak.recent[i]),
                  ],
                ],
              ),
            ),
          ),
          if (pause != null || undo != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: ValueKey(pause != null ? 'streak-pause' : 'streak-undo'),
                style: TextButton.styleFrom(
                  foregroundColor: t.inkSecondary,
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(48, 48),
                  alignment: Alignment.centerLeft,
                  tapTargetSize: MaterialTapTargetSize.padded,
                ),
                onPressed: () =>
                    pause != null ? onPause!(pause) : onUndoPause!(undo!),
                child: Text(
                  pause == null
                      ? 'Undo pause'
                      : pause == 0
                      ? 'Sore or ill? Pause this week'
                      : 'Sore or ill last week? Pause it',
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

class _WeekDot extends StatelessWidget {
  const _WeekDot({required this.state});

  final engine.StreakWeek state;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final ran = state == engine.StreakWeek.ran;
    final frozen = state == engine.StreakWeek.frozen;
    final paused = state == engine.StreakWeek.paused;
    final colour = frozen ? t.laneFill(engine.IdentityLane.long) : t.inkPrimary;
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: ran || frozen ? colour : Colors.transparent,
        border: Border.all(
          color: ran || frozen
              ? colour
              : paused
              ? t.inkSecondary
              : t.inkMuted,
          width: 2,
        ),
      ),
      child: frozen
          ? Icon(Icons.ac_unit, size: 7, color: readableOn(colour))
          : paused
          ? Icon(Icons.pause, size: 7, color: t.inkSecondary)
          : null,
    );
  }
}
