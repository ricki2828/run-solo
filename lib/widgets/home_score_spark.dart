import 'package:flutter/material.dart';

/// A small trend line for one score card: percentile values oldest to
/// newest. Mint when rising, muted when flat or falling; nothing at all
/// with fewer than two points.
class HomeScoreSpark extends StatelessWidget {
  const HomeScoreSpark({
    super.key,
    required this.values,
    required this.rising,
    required this.mutedColor,
    this.height = 20,
  });

  /// Oldest to newest.
  final List<int> values;
  final Color rising;
  final Color mutedColor;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (values.length < 2) return const SizedBox.shrink();
    final up = values.last > values.first;
    return ExcludeSemantics(
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: HomeScoreSparkPainter(
            values: values,
            color: up ? rising : mutedColor,
          ),
        ),
      ),
    );
  }
}

class HomeScoreSparkPainter extends CustomPainter {
  HomeScoreSparkPainter({required this.values, required this.color});
  final List<int> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    const pad = 3.0;
    final lo = values.reduce((a, b) => a < b ? a : b);
    final hi = values.reduce((a, b) => a > b ? a : b);
    final span = (hi - lo).toDouble();
    final w = size.width - pad * 2, h = size.height - pad * 2;
    Offset at(int i) => Offset(
      pad + w * i / (values.length - 1),
      // Flat lines sit mid-height.
      span == 0 ? size.height / 2 : pad + h * (1 - (values[i] - lo) / span),
    );
    final path = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < values.length; i++) {
      path.lineTo(at(i).dx, at(i).dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawCircle(at(values.length - 1), 3, Paint()..color = color);
  }

  @override
  bool shouldRepaint(HomeScoreSparkPainter old) =>
      old.color != color || old.values.join(',') != values.join(',');
}
