import 'package:flutter/material.dart';

import '../../theme/theme.dart';

/// The small pill that sits on a block: "WEEK 2", "LEVEL 14". [fill] and
/// [ink] are for the block it sits on.
class BlockChip extends StatelessWidget {
  const BlockChip({
    super.key,
    required this.label,
    required this.fill,
    required this.ink,
  });

  final String label;
  final Color fill;
  final Color ink;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: Space.x8, vertical: 5),
    decoration: BoxDecoration(
      color: fill,
      borderRadius: BorderRadius.circular(Radii.pill),
    ),
    child: Text(
      label,
      maxLines: 1,
      style: RunSoloType.micro11.copyWith(
        color: ink,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}
