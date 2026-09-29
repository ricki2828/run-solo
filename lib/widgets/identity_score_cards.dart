import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../theme/theme.dart';

/// Identity is earned by a run, never by a per-session verdict. The Aerobic
/// card uses the existing fitness hero itself, not a second VO2 calculation.
class IdentityScoreCards extends StatelessWidget {
  const IdentityScoreCards({
    super.key,
    required this.scores,
    required this.hero,
    this.onOpen,
  });

  final Map<engine.IdentityLane, engine.IdentityScore> scores;
  final engine.FitnessHero? hero;
  final ValueChanged<engine.IdentityScore>? onOpen;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('YOUR SCORES', style: RunSoloType.micro11.copyWith(color: t.inkSecondary)),
        const SizedBox(height: Space.x12),
        for (final pair in const [
          [engine.IdentityLane.aerobic, engine.IdentityLane.speed],
          [engine.IdentityLane.mid, engine.IdentityLane.long],
        ]) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final lane in pair) ...[
                Expanded(child: _ScoreCard(
                  lane: lane,
                  score: scores[lane],
                  hero: lane == engine.IdentityLane.aerobic ? hero : null,
                  onTap: scores[lane] == null || onOpen == null
                      ? null : () => onOpen!(scores[lane]!),
                )),
                if (lane == pair.first) const SizedBox(width: Space.x12),
              ],
            ],
          ),
          if (pair.first == engine.IdentityLane.aerobic)
            const SizedBox(height: Space.x12),
        ],
      ],
    );
  }
}

class _ScoreCard extends StatelessWidget {
  const _ScoreCard({required this.lane, this.score, this.hero, this.onTap});
  final engine.IdentityLane lane;
  final engine.IdentityScore? score;
  final engine.FitnessHero? hero;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final active = score != null;
    final color = !active ? t.inkMuted : switch (lane) {
      engine.IdentityLane.aerobic =>
        hero?.sourceLabel == 'Cooper test' ? AuroraRunType.tests : AuroraRunType.free,
      engine.IdentityLane.speed => AuroraRunType.intervals,
      engine.IdentityLane.mid => AuroraRunType.goal,
      engine.IdentityLane.long => AuroraRunType.free,
    };
    final label = lane.name.toUpperCase();
    final unlock = switch (lane) {
      engine.IdentityLane.aerobic => 'Your first session sets it.',
      engine.IdentityLane.speed => 'Log a clean interval session to unlock SPEED',
      engine.IdentityLane.mid => 'Log a 5K+ effort to unlock MID',
      engine.IdentityLane.long => 'Log a 15K+ run to unlock LONG',
    };
    return Semantics(
      button: active && onTap != null,
      label: active ? '$label ${score!.score} out of 99, ${score!.source}' : '$label locked. $unlock',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.card),
        child: Container(
          constraints: const BoxConstraints(minHeight: 156),
          padding: const EdgeInsets.all(Space.x12),
          decoration: BoxDecoration(
            color: t.bgRaised,
            border: Border.all(color: active ? color.withValues(alpha: 0.5) : t.lineHair),
            borderRadius: BorderRadius.circular(Radii.card),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: RunSoloType.micro11.copyWith(color: color)),
              const SizedBox(height: Space.x8),
              if (!active) ...[
                Text('LOCKED', style: RunSoloType.heading19.copyWith(color: t.inkMuted)),
                const SizedBox(height: Space.x8),
                Text(lane == engine.IdentityLane.aerobic ? 'NO BASELINE YET' : unlock,
                    style: RunSoloType.label13.copyWith(color: t.inkSecondary)),
                if (lane == engine.IdentityLane.aerobic)
                  Text('Your first session sets it.', style: RunSoloType.label13.copyWith(color: t.inkSecondary)),
              ] else ...[
                Text('${score!.score}', style: RunSoloType.display64.copyWith(color: color)),
                Text(score!.changeVs6Weeks == null
                    ? 'First score'
                    : score!.changeVs6Weeks! > 0
                    ? '+${score!.changeVs6Weeks} vs 6 wks'
                    : '${score!.changeVs6Weeks} vs 6 wks',
                  style: RunSoloType.label13.copyWith(color: t.inkSecondary)),
                if (hero != null)
                  Text('VO2 max ${hero!.vo2.toStringAsFixed(1)} ml/kg',
                    style: RunSoloType.label13.copyWith(color: t.inkSecondary)),
                Text('${score!.source} · ${Fmt.dayDate(score!.date)} ›',
                    maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: RunSoloType.label13.copyWith(color: t.inkSecondary)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
