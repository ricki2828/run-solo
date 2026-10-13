import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../../app/format.dart';
import '../../state/companion.dart';
import '../../theme/lanes.dart';
import '../../theme/theme.dart';
import '../section_card.dart';
import 'block_chip.dart';

/// The coach's next session and latest line, on Home under the plan card.
/// Fed by `GET /v1/me/next-session`; Home builds nothing when there is no
/// reply. When the coach moved the session it says so. The 4-week plan is not
/// changed by this card.
class CoachNextCard extends StatelessWidget {
  const CoachNextCard({super.key, required this.next, required this.now});

  final CoachNext next;
  final DateTime now;

  /// A coach line older than this is not "latest" any more.
  static const Duration lineFresh = Duration(days: 7);

  static engine.IdentityLane laneOf(String type) => switch (type) {
    'long' => engine.IdentityLane.long,
    'quality' => engine.IdentityLane.speed,
    _ => engine.IdentityLane.aerobic,
  };

  /// "Today", "Tomorrow" or "Mon 19 Oct".
  static String dayWords(DateTime day, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final diff = DateTime(
      day.year,
      day.month,
      day.day,
    ).difference(today).inDays;
    return switch (diff) {
      0 => 'Today',
      1 => 'Tomorrow',
      _ => Fmt.dayDate(day),
    };
  }

  /// False when the session's day has already gone by.
  static bool upcoming(CoachSession s, DateTime now) =>
      !s.date.isBefore(DateTime(now.year, now.month, now.day));

  /// The session to show: not one whose day has gone by.
  static CoachSession? sessionFor(CoachNext n, DateTime now) =>
      n.session != null && upcoming(n.session!, now) ? n.session : null;

  /// The line to show: not one older than [lineFresh].
  static CoachLine? lineFor(CoachNext n, DateTime now) =>
      n.line != null &&
          (n.line!.sentAt == null ||
              now.toUtc().difference(n.line!.sentAt!.toUtc()) < lineFresh)
      ? n.line
      : null;

  /// False when there is nothing worth a card.
  static bool visible(CoachNext n, DateTime now) =>
      sessionFor(n, now) != null || lineFor(n, now) != null;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final session = sessionFor(next, now);
    final line = lineFor(next, now);
    if (session == null && line == null) return const SizedBox.shrink();
    final lane = session == null
        ? engine.IdentityLane.mid
        : laneOf(session.type);
    return SectionCard(
      key: const ValueKey('home-coach-card'),
      accent: t.laneFill(lane),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'YOUR COACH',
                  style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
                ),
              ),
              if (session != null && session.moved)
                BlockChip(
                  key: const ValueKey('home-coach-moved'),
                  label: 'MOVED BY YOUR COACH',
                  fill: t.laneFill(lane),
                  ink: t.laneText(lane),
                ),
            ],
          ),
          if (session != null) ...[
            const SizedBox(height: Space.x8),
            Text(
              'NEXT SESSION',
              style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
            ),
            const SizedBox(height: Space.x4),
            Text(
              '${dayWords(session.date, now)}: ${session.title}',
              key: const ValueKey('home-coach-session'),
              style: RunSoloType.body17.copyWith(
                color: t.inkPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (session.moved && session.originalDate != null) ...[
              const SizedBox(height: Space.x4),
              Text(
                'Was ${Fmt.dayDate(session.originalDate!)}',
                key: const ValueKey('home-coach-was'),
                style: RunSoloType.label13.copyWith(color: t.inkSecondary),
              ),
            ],
          ],
          if (line != null) ...[
            if (session != null) const SizedBox(height: Space.x12),
            Text(
              line.headline,
              key: const ValueKey('home-coach-headline'),
              style: RunSoloType.body15.copyWith(
                color: t.inkPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (line.body != null) ...[
              const SizedBox(height: Space.x4),
              Text(
                line.body!,
                key: const ValueKey('home-coach-body'),
                style: RunSoloType.body15.copyWith(color: t.inkSecondary),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
