import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import 'recent_bars_chart.dart';

/// Your runs on one trail as [RecentBarsChart] bars: moving time, faster is
/// taller, the best run dashed. The one chart the run detail section and the
/// trail board share.
class TrailRunsChart extends StatelessWidget {
  const TrailRunsChart({
    super.key,
    required this.group,
    this.chartKey,
    this.showValues = true,
  });
  final engine.TrailGroup group;
  final Key? chartKey;

  /// The values list under the bars; off where the screen has its own table.
  final bool showValues;

  @override
  Widget build(BuildContext context) {
    final best = group.best;
    return RecentBarsChart(
      key: chartKey,
      points: [
        for (final r in group.runs)
          BarPoint(date: r.start, value: r.movingMs / 1000),
      ],
      lowerIsBetter: true,
      format: (v) => Fmt.clock((v * 1000).round()),
      direction: 'Faster is taller',
      emptyTitle: 'Two runs on this trail draw the first chart.',
      best: best.movingMs / 1000,
      roundTo: 10,
      showValues: showValues,
      caption: 'Moving time on ${group.name}',
    );
  }
}
