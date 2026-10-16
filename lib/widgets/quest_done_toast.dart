import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// "QUEST DONE · SADDLE ×5": the 4 s toast on the record screen when a quest
/// completes mid-run. A solid pill in the foreground colour of the flood (like
/// the turn-around card), so it reads on every zone colour, with the 36 sp
/// minimum for anything on the record screen (A8).
class QuestDoneToast extends StatelessWidget {
  const QuestDoneToast({
    super.key,
    required this.text,
    required this.fill,
    required this.ink,
    this.compact = false,
  });

  /// "QUEST DONE · SADDLE ×5".
  final String text;
  final Color fill;
  final Color ink;
  final bool compact;

  /// How long it stays.
  static const Duration shownFor = Duration(seconds: 4);

  @override
  Widget build(BuildContext context) {
    final size = RunSoloType.runSize(compact ? 36 : 44);
    return Semantics(
      liveRegion: true,
      label: text,
      child: Container(
        key: const ValueKey('quest-done-toast'),
        margin: const EdgeInsets.only(top: Space.x8),
        padding: const EdgeInsets.symmetric(
          horizontal: Space.x12,
          vertical: Space.x8,
        ),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(Radii.chip),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            text,
            key: const ValueKey('quest-done-text'),
            softWrap: false,
            style: RunSoloType.display44.copyWith(
              fontSize: size,
              color: ink,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }
}
