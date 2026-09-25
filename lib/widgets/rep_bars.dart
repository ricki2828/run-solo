import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../platform/gateway.dart';
import '../theme/theme.dart';
import 'delta_glyph.dart';

/// One row of the verdict / detail rep chart (design brief §2.2 data-viz).
@immutable
class RepBarDatum {
  const RepBarDatum({
    required this.label,
    required this.paceSecPerKm,
    this.ghostSecPerKm,
    this.excluded = false,
    this.reason,
  });
  final String label;

  /// Null = no pace (interrupted rep, no GPS): hatched bar.
  final double? paceSecPerKm;

  /// Last run's matching rep, drawn behind at 40 % muted.
  final double? ghostSecPerKm;
  final bool excluded;
  final String? reason;
}

enum RepTone { neutral, faster, slower, arc }

/// Horizontal rep bars, 28 px, Bone; bar length = pace on a shared scale
/// (faster = longer), ghost bar behind, delta label right-aligned in the
/// semantic colour, excluded reps hatched. `progress` 0–1 slides the bars in
/// for M4 (stagger 50 ms per bar over the first 300 ms); `fadeProgress`
/// draws the slope line across the bar ends (300–700 ms).
class RepBars extends StatelessWidget {
  const RepBars({
    super.key,
    required this.reps,
    required this.units,
    this.progress = 1,
    this.fadeProgress = 1,
    this.tone = RepTone.neutral,
    this.showDelta = true,
  });

  final List<RepBarDatum> reps;
  final Units units;
  final double progress;
  final double fadeProgress;
  final RepTone tone;
  final bool showDelta;

  static const double barHeight = 28;
  static const double rowGap = 8;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final paces = [
      for (final r in reps) ...[
        if (r.paceSecPerKm != null) r.paceSecPerKm!,
        if (r.ghostSecPerKm != null) r.ghostSecPerKm!,
      ],
    ];
    // Shared scale: slowest pace in view → 45 % width, fastest → 100 %.
    final slowest = paces.isEmpty ? 0.0 : paces.reduce((a, b) => a > b ? a : b);
    final fastest = paces.isEmpty ? 0.0 : paces.reduce((a, b) => a < b ? a : b);
    double frac(double? pace) {
      if (pace == null) return 0.45;
      if (slowest - fastest < 1) return 1;
      return 1 - 0.55 * (pace - fastest) / (slowest - fastest);
    }

    final barColor = switch (tone) {
      RepTone.arc => t.accentArc,
      _ => t.inkPrimary,
    };
    return Semantics(
      label:
          'Rep paces: ${reps.map((r) => '${r.label} ${Fmt.pace(r.paceSecPerKm, units)}').join(', ')}',
      child: LayoutBuilder(
        builder: (context, c) {
          const labelW = 112.0;
          final trackW = c.maxWidth - labelW - Space.x12;
          final ends = <Offset>[];
          final rows = <Widget>[];
          for (var i = 0; i < reps.length; i++) {
            final r = reps[i];
            final stagger = ((progress * reps.length) - i).clamp(0.0, 1.0);
            final eased = MotionCurves.emphasized.transform(stagger);
            final w = trackW * frac(r.paceSecPerKm) * eased;
            ends.add(Offset(w, i * (barHeight + rowGap) + barHeight / 2));
            final delta = r.ghostSecPerKm == null || r.paceSecPerKm == null
                ? null
                : r.paceSecPerKm! - r.ghostSecPerKm!;
            // Cyan is earned by the verdict, not by a rep: deltas take the
            // verdict's tone. NO REAL CHANGE / HOLDING / BASELINE stay in ink
            // even when single reps came in a few seconds faster.
            final deltaColor = switch (tone) {
              RepTone.arc => t.accentArc,
              RepTone.faster => t.semFaster,
              RepTone.slower => t.semSlower,
              RepTone.neutral => t.inkSecondary,
            };
            rows.add(
              SizedBox(
                height: barHeight,
                child: Row(
                  children: [
                    SizedBox(
                      width: trackW,
                      child: Stack(
                        alignment: Alignment.centerLeft,
                        children: [
                          if (r.ghostSecPerKm != null)
                            Container(
                              width: trackW * frac(r.ghostSecPerKm),
                              height: barHeight,
                              decoration: BoxDecoration(
                                color: t.inkMuted.withValues(alpha: 0.4),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          if (r.excluded || r.paceSecPerKm == null)
                            CustomPaint(
                              size: Size(w, barHeight),
                              painter: _HatchPainter(t.semNoise),
                            )
                          else
                            Container(
                              width: w,
                              height: barHeight,
                              decoration: BoxDecoration(
                                color: barColor,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: Space.x12),
                    SizedBox(
                      width: labelW,
                      child: Opacity(
                        opacity: eased,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Text(
                              Fmt.pace(r.paceSecPerKm, units),
                              style: RunSoloType.label13.copyWith(
                                color: r.excluded ? t.semNoise : t.inkPrimary,
                                fontSize: 15,
                              ),
                            ),
                            if (showDelta && delta != null) ...[
                              const SizedBox(width: Space.x8),
                              DeltaGlyph(
                                direction: DeltaGlyph.forDelta(delta),
                                color: deltaColor,
                                size: 10,
                              ),
                              const SizedBox(width: 2),
                              Text(
                                _delta(delta, units),
                                style: RunSoloType.label13.copyWith(
                                  color: deltaColor,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
            if (i < reps.length - 1) rows.add(const SizedBox(height: rowGap));
          }
          final slopeColor = switch (tone) {
            RepTone.faster || RepTone.arc => t.semFaster,
            RepTone.slower => t.semSlower,
            RepTone.neutral => t.inkSecondary,
          };
          return Stack(
            children: [
              Column(children: rows),
              if (reps.length >= 2 && fadeProgress > 0)
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _FadeSlopePainter(
                        ends: ends,
                        progress: fadeProgress,
                        color: slopeColor,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// "▲16" faster / "▼12" slower / "▬0".
  static String _delta(double deltaSecPerKm, Units units) {
    final d = engine.PaceFormat.toUnit(
      deltaSecPerKm,
      units == Units.mi ? engine.Units.mi : engine.Units.km,
    ).round();
    return '${d.abs()}';
  }
}

class _HatchPainter extends CustomPainter {
  _HatchPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0) return;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(2),
    );
    canvas.save();
    canvas.clipRRect(rrect);
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var x = -size.height; x < size.width + size.height; x += 4) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), p);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_HatchPainter old) => old.color != color;
}

/// The fade slope across the bar ends, drawn left to right.
class _FadeSlopePainter extends CustomPainter {
  _FadeSlopePainter({
    required this.ends,
    required this.progress,
    required this.color,
  });
  final List<Offset> ends;
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (ends.length < 2) return;
    final path = Path()..moveTo(ends.first.dx, ends.first.dy);
    for (final e in ends.skip(1)) {
      path.lineTo(e.dx, e.dy);
    }
    for (final m in path.computeMetrics()) {
      canvas.drawPath(
        m.extractPath(0, m.length * progress.clamp(0, 1)),
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_FadeSlopePainter old) =>
      old.progress != progress || old.ends != ends || old.color != color;
}
