import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../../app/routes.dart';
import '../../state/home_progress.dart';
import '../../state/settings.dart';
import '../home_scores.dart' show laneUnlockApply;
import 'lane_block.dart';

/// The four scores as lane-colour blocks. An earned lane shows its percentile
/// against the age band; a lane not set yet is still in colour and opens
/// Start on the format that sets it, so week one is a to-do list in colour.
class HomeLaneBlocks extends StatelessWidget {
  const HomeLaneBlocks({
    super.key,
    required this.scores,
    required this.profileSex,
    required this.age,
    required this.onOpen,
    required this.onUnlock,
  });

  final Map<engine.IdentityLane, engine.IdentityScore> scores;
  final ProfileSex profileSex;
  final int? age;
  final VoidCallback onOpen;
  final void Function(AppSettings Function(AppSettings)) onUnlock;

  static const _setBy = {
    engine.IdentityLane.aerobic: '12 min test',
    engine.IdentityLane.speed: '8\u00A0x\u00A0400',
    engine.IdentityLane.mid: '5K or 10K',
    engine.IdentityLane.long: '15K+',
  };

  @override
  Widget build(BuildContext context) => LaneBlockRow(
    blocks: [
      for (final lane in engine.IdentityLane.values)
        _block(context, lane, scores[lane]),
    ],
  );

  LaneBlock _block(
    BuildContext context,
    engine.IdentityLane lane,
    engine.IdentityScore? score,
  ) {
    if (score == null) {
      return LaneBlock(
        key: ValueKey('home-unlock-${lane.name}'),
        lane: lane,
        value: null,
        caption: 'Unlock: ${_setBy[lane]!}',
        onTap: () => onUnlock(laneUnlockApply(lane)),
      );
    }
    final p = ScoreNorms.percentile(
      lane,
      score.vdot,
      score.source,
      sex: profileSex,
      age: age,
    );
    final known = p != null;
    return LaneBlock(
      key: ValueKey('home-score-${lane.name}'),
      lane: lane,
      value: known ? '$p' : null,
      change: known
          ? ScoreNorms.change(score, sex: profileSex, age: age)
          : null,
      caption: known ? 'of your age band' : 'Add age and sex',
      onTap: known
          ? onOpen
          : () => Navigator.of(context).pushNamed(Routes.settings),
    );
  }
}
