import 'package:flutter/material.dart';

import '../../theme/lanes.dart';
import '../../theme/theme.dart';

/// The title block that opens a result or detail screen: a flat run-type
/// colour block (the same colour as the run's card on Home), ink picked for
/// contrast. [builder] gets that ink so the text inside stays readable.
class ResultHeadBlock extends StatelessWidget {
  const ResultHeadBlock({
    super.key,
    required this.fill,
    required this.builder,
    this.padding = const EdgeInsets.all(Space.x16),
  });

  final Color fill;
  final Widget Function(BuildContext context, Color ink) builder;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: padding,
    decoration: BoxDecoration(
      color: fill,
      borderRadius: BorderRadius.circular(Radii.sheet),
    ),
    child: builder(context, readableOn(fill)),
  );
}
