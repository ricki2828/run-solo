import 'package:flutter/material.dart';

import '../state/zone_histogram.dart';
import '../theme/zones.dart';

/// A thin strip of a run's time in each HR zone, Z1 to Z5 left to right, in
/// the zone ramp. History rows carry one under the run; nothing is drawn for
/// a run with no heart rate ([ZoneShares.from] is null then).
///
/// [seconds] is [zoneSecondsOf]'s layout (index 0 unused here).
class ZoneStrip extends StatelessWidget {
  const ZoneStrip({super.key, required this.seconds, this.height = 6});
  final List<double> seconds;
  final double height;

  static const double gap = 1.5;

  @override
  Widget build(BuildContext context) {
    final shares = ZoneShares.from(seconds);
    if (shares == null) return const SizedBox.shrink();
    final brightness = Theme.of(context).brightness;
    final labels = [
      for (var z = 1; z <= 5; z++)
        if (shares.percents[z - 1] > 0) 'Z$z ${shares.percents[z - 1]}%',
    ];
    return Semantics(
      label: 'Time in zone: ${labels.join(', ')}',
      child: ExcludeSemantics(
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(
            painter: _ZoneStripPainter(
              seconds: shares.seconds,
              colors: [
                for (var z = 1; z <= 5; z++)
                  HrZones.distribution(z, brightness),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ZoneStripPainter extends CustomPainter {
  _ZoneStripPainter({required this.seconds, required this.colors});
  final List<double> seconds;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final total = seconds.fold(0.0, (a, b) => a + b);
    if (total <= 0 || size.width <= 0) return;
    final used = [
      for (var z = 0; z < 5; z++)
        if (seconds[z] > 0) z,
    ];
    final room = size.width - ZoneStrip.gap * (used.length - 1);
    var x = 0.0;
    for (final z in used) {
      final w = room * seconds[z] / total;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, 0, w, size.height),
          Radius.circular(size.height / 2),
        ),
        Paint()..color = colors[z],
      );
      x += w + ZoneStrip.gap;
    }
  }

  @override
  bool shouldRepaint(_ZoneStripPainter old) =>
      old.seconds != seconds || old.colors != colors;
}
