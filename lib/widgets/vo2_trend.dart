/// The last tests' raw VO2 estimates as bars (CO2 result; design A11
/// "recent runs" rules, compact): taller is better on a cropped baseline
/// said on the axis, `ink.muted` bars, this test in Bone, the best in Arc
/// (the best wins when this test is the best). Raw only, never the heat
/// twin (plan §3.3).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/theme.dart';

class Vo2Bars extends StatelessWidget {
  const Vo2Bars({
    super.key,
    required this.values,
    required this.best,
    this.hollow,
    this.height = 96,
  });

  /// The shown tests, oldest first; the last is this test. At most
  /// [maxBars].
  final List<double> values;

  /// The best estimate up to this test on this test's surface (it may be older
  /// than the bars).
  final double best;

  /// Per bar: true for a test run on a treadmill, drawn as an outline instead
  /// of a fill (a belt is not a road). Null or empty = all outdoor. The best
  /// and the Arc colour only go to a bar on the same surface as the last one.
  final List<bool>? hollow;

  bool _hollowAt(int i) {
    final h = hollow;
    return h != null && i < h.length && h[i];
  }

  final double height;

  static const int maxBars = 10;

  /// Where the value axis starts (A11): 10% of the shown range past the
  /// lowest shown value, rounded down to a whole VO2.
  static int baselineOf(List<double> values) {
    final lo = values.reduce(math.min), hi = values.reduce(math.max);
    final pad = math.max((hi - lo) * 0.1, 1.0);
    return (lo - pad).floor();
  }

  /// The index of the best bar, or null when the best is older than the
  /// bars (ties go to the earliest, as a board ranks them).
  int? get bestIndex {
    final surface = _hollowAt(values.length - 1);
    for (var i = 0; i < values.length; i++) {
      if (_hollowAt(i) == surface && values[i] >= best) return i;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final base = baselineOf(values);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(
            painter: _Vo2BarsPainter(
              values,
              baseline: base.toDouble(),
              top: math.max(values.reduce(math.max), best),
              bestIndex: bestIndex,
              hollow: [for (var i = 0; i < values.length; i++) _hollowAt(i)],
              muted: t.inkMuted,
              current: t.inkPrimary,
              arc: t.accentArc,
              hair: t.lineHair,
            ),
          ),
        ),
        const SizedBox(height: Space.x4),
        Text(
          'Axis starts at VO2 $base',
          key: const ValueKey('vo2-bars-axis'),
          style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
        ),
        if (hollow?.any((h) => h) ?? false)
          Text(
            'Outlined bars are treadmill tests.',
            key: const ValueKey('vo2-bars-legend'),
            style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
          ),
      ],
    );
  }
}

class _Vo2BarsPainter extends CustomPainter {
  _Vo2BarsPainter(
    this.values, {
    required this.baseline,
    required this.top,
    required this.bestIndex,
    required this.hollow,
    required this.muted,
    required this.current,
    required this.arc,
    required this.hair,
  });
  final List<double> values;
  final double baseline;
  final double top;
  final int? bestIndex;
  final List<bool> hollow;
  final Color muted;
  final Color current;
  final Color arc;
  final Color hair;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(
      Offset(0, size.height),
      Offset(size.width, size.height),
      Paint()..color = hair,
    );
    // One slot per possible bar, left-aligned, so a first few tests don't
    // stretch across the width.
    final slot = size.width / Vo2Bars.maxBars;
    final w = math.min(20.0, slot * 0.62);
    final span = top - baseline;
    for (var i = 0; i < values.length; i++) {
      final f = span <= 0 ? 1.0 : ((values[i] - baseline) / span).clamp(0, 1);
      final h = math.max(2.0, size.height * f);
      final x = slot * i + (slot - w) / 2;
      final color = i == bestIndex
          ? arc
          : i == values.length - 1
          ? current
          : muted;
      final bar = RRect.fromRectAndCorners(
        Rect.fromLTWH(x, size.height - h, w, h),
        topLeft: const Radius.circular(3),
        topRight: const Radius.circular(3),
      );
      if (hollow[i]) {
        // A treadmill test: an outline, inset so the stroke stays in the slot.
        canvas.drawRRect(
          bar.deflate(1),
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      } else {
        canvas.drawRRect(bar, Paint()..color = color);
      }
    }
  }

  @override
  bool shouldRepaint(_Vo2BarsPainter old) =>
      old.values != values ||
      old.bestIndex != bestIndex ||
      old.hollow != hollow;
}
