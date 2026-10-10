/// The size of a metric label on the record screen. The record screen sets
/// it ([RunLabelScope]); a label anywhere under it reads [RunLabelScope.style].
/// Default 17 sp, so labels read at arm's length mid-run (founder, 10-Oct
/// trail run); structured sessions, which also carry the coach layer, step
/// down so everything still fits on a short phone. Numbers are untouched.
library;

import 'package:flutter/widgets.dart';

import 'typography.dart';

class RunLabelScope extends InheritedWidget {
  const RunLabelScope({super.key, required this.size, required super.child});

  final double size;

  /// Labels when nothing above says otherwise.
  static const double defaultSize = 17;

  static double sizeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RunLabelScope>()?.size ??
      defaultSize;

  /// The label style at the scope's size, in [color].
  static TextStyle style(BuildContext context, Color color) {
    final size = sizeOf(context);
    return RunSoloType.runLabel.copyWith(
      color: color,
      fontSize: size,
      letterSpacing: size * 0.05,
    );
  }

  @override
  bool updateShouldNotify(RunLabelScope old) => old.size != size;
}

extension RunLabelScopeX on Widget {
  /// This widget under a [RunLabelScope] of [size].
  Widget labelScope(double size) => RunLabelScope(size: size, child: this);
}
