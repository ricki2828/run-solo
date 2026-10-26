import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../theme/theme.dart';
import '../theme/zones.dart';

/// How a bar is outlined: this week is solid ink (or amber for a big jump),
/// a week or month still being run is dashed.
enum LoadBarOutline { none, solid, dashed }

/// One bar of [LoadBars].
class LoadBarData {
  const LoadBarData({
    required this.label,
    this.load = 0,
    this.zoneShare = const [0, 0, 0, 0, 0],
    this.noHrShare = 0,
    this.zoned = true,
    this.paused = false,
    this.stub = false,
    this.outline = LoadBarOutline.none,
    this.warn = false,
    this.tag,
  });

  /// A calendar week. [label] is the two-line date under the bar.
  factory LoadBarData.week(
    engine.WeekLoad w, {
    required String label,
    LoadBarOutline outline = LoadBarOutline.none,
    bool warn = false,
    String? tag,
  }) => LoadBarData(
    label: label,
    load: w.load,
    zoneShare: w.zoneShare,
    noHrShare: w.noHrShare,
    paused: w.paused,
    // Before the first run: a short hairline, not a rest week.
    stub: w.beforeStart,
    outline: outline,
    warn: warn,
    tag: tag,
  );

  /// A calendar month: total load only, so one flat colour.
  factory LoadBarData.period(
    engine.PeriodLoad p, {
    required String label,
    LoadBarOutline outline = LoadBarOutline.none,
    String? tag,
  }) => LoadBarData(
    label: label,
    load: p.load,
    zoned: false,
    stub: p.future || p.beforeStart,
    outline: outline,
    tag: tag,
  );

  final String label;
  final double load;

  /// Share of moving time in zones 1-5 (index 0 is zone 1).
  final List<double> zoneShare;

  /// The part of the bar with no heart rate: ice, never grey.
  final double noHrShare;

  /// False for a month or year: no zone split, one flat ink bar.
  final bool zoned;
  final bool paused;

  /// A hairline in place of a bar: before the first run, or a month yet to
  /// come.
  final bool stub;
  final LoadBarOutline outline;

  /// Amber outline for this week's bar (a big jump only).
  final bool warn;

  /// "THIS WEEK" / "SO FAR" above the bar.
  final String? tag;
}

/// Load per period as zone-stacked bars (zone 1 at the bottom), with a dashed
/// "usual" line across the bars it was averaged from. Taller is more load;
/// the number on a bar is never drawn, the hero above carries it.
class LoadBars extends StatelessWidget {
  const LoadBars({
    super.key,
    required this.bars,
    this.usual,
    this.usualFrom = 0,
    this.usualTo,
    this.barsHeight = 120,
    this.grow = 1,
    this.semanticsLabel,
    this.labelStyle,
  });

  final List<LoadBarData> bars;

  /// The usual load; the line is drawn from bar [usualFrom] to the right
  /// edge, labelled in the gutter. Null draws no line and no gutter.
  final double? usual;
  final int usualFrom;

  /// The last bar the line covers; null runs it to the right edge.
  final int? usualTo;

  /// Height of the bar area (the tags and the date labels sit outside it).
  final double barsHeight;

  /// 0..1 entrance: bars rise from the baseline.
  final double grow;
  final String? semanticsLabel;
  final TextStyle? labelStyle;

  static const double _tagH = 28;
  static const double _gutter = 70;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final brightness = Theme.of(context).brightness;
    final hasUsual = usual != null && usual! > 0;
    final peak = bars.fold<double>(
      hasUsual ? usual! : 0,
      (a, b) => math.max(a, b.load),
    );
    final scale = peak <= 0 ? 1.0 : peak * 1.04;
    final style = labelStyle ?? RunSoloType.label13;
    return Semantics(
      container: true,
      label: semanticsLabel,
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, box) {
            final width = box.maxWidth - (hasUsual ? _gutter : 0);
            final slot = bars.isEmpty ? width : width / bars.length;
            final barW = (slot * 0.62).clamp(12.0, 30.0);
            final usualY =
                _tagH +
                barsHeight -
                (hasUsual ? usual! / scale : 0) * barsHeight;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: _tagH + barsHeight,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      for (var i = 0; i < bars.length; i++)
                        Positioned(
                          left: i * slot,
                          width: slot,
                          top: 0,
                          bottom: 0,
                          child: _Cell(
                            key: ValueKey('load-bar-$i'),
                            data: bars[i],
                            barW: barW,
                            barsHeight: barsHeight,
                            fraction: bars[i].load / scale,
                            grow: grow.clamp(0.0, 1.0),
                            t: t,
                            brightness: brightness,
                          ),
                        ),
                      if (hasUsual) ...[
                        Positioned.fill(
                          child: CustomPaint(
                            key: const ValueKey('load-usual-line'),
                            painter: _UsualLine(
                              y: usualY,
                              x0: usualFrom * slot + 2,
                              x1: usualTo == null
                                  ? width
                                  : (usualTo! + 1) * slot - 2,
                              colour: t.inkSecondary,
                            ),
                          ),
                        ),
                        Positioned(
                          left: width + 6,
                          width: _gutter - 6,
                          top: math.max(0, usualY - 8),
                          child: Text(
                            'Usual ${usual!.round()}',
                            maxLines: 1,
                            softWrap: false,
                            style: RunSoloType.micro11.copyWith(
                              color: t.inkSecondary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: Space.x8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final b in bars)
                      SizedBox(
                        width: slot,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            b.label,
                            textAlign: TextAlign.center,
                            softWrap: false,
                            style: style.copyWith(color: t.inkSecondary),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({
    super.key,
    required this.data,
    required this.barW,
    required this.barsHeight,
    required this.fraction,
    required this.grow,
    required this.t,
    required this.brightness,
  });
  final LoadBarData data;
  final double barW;
  final double barsHeight;
  final double fraction;
  final double grow;
  final RunSoloTokens t;
  final Brightness brightness;

  @override
  Widget build(BuildContext context) {
    final d = data;
    final stubbed = d.paused || d.stub || d.load <= 0;
    final h = stubbed
        ? (d.stub ? 2.0 : (d.paused ? 3.0 : 4.0))
        : math.max(6.0, fraction * barsHeight * grow);
    final outline = d.warn ? t.semWarn : t.inkPrimary;
    final zoneTotal =
        d.zoneShare.fold<double>(0, (a, b) => a + b) + d.noHrShare;
    final colours = <Color>[];
    final shares = <double>[];
    if (!stubbed) {
      if (d.zoned && zoneTotal > 0) {
        for (var z = 0; z < 5; z++) {
          colours.add(HrZones.distribution(z + 1, brightness));
          shares.add(d.zoneShare[z] / zoneTotal);
        }
        colours.add(t.typeFree);
        shares.add(d.noHrShare / zoneTotal);
      } else if (d.zoned) {
        colours.add(t.typeFree);
        shares.add(1);
      } else {
        colours.add(t.inkPrimary.withValues(alpha: 0.85));
        shares.add(1);
      }
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: 0,
          right: 0,
          bottom: h + 4,
          child: d.paused
              ? FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    'PAUSED',
                    softWrap: false,
                    style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
                  ),
                )
              : d.tag == null
              ? const SizedBox.shrink()
              // On the card colour so the usual line never strikes the words.
              : Center(
                  child: ColoredBox(
                    color: t.bgRaised,
                    child: Text(
                      d.tag!,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      style: RunSoloType.micro11.copyWith(color: t.inkPrimary),
                    ),
                  ),
                ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: h,
          child: Center(
            child: SizedBox(
              width: barW,
              height: h,
              child: CustomPaint(
                painter: _BarPainter(
                  colours: colours,
                  shares: shares,
                  stub: t.lineHair,
                  stubbed: stubbed,
                  outline: stubbed ? LoadBarOutline.none : d.outline,
                  outlineColour: outline,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter({
    required this.colours,
    required this.shares,
    required this.stub,
    required this.stubbed,
    required this.outline,
    required this.outlineColour,
  });
  final List<Color> colours;
  final List<double> shares;
  final Color stub;
  final bool stubbed;
  final LoadBarOutline outline;
  final Color outlineColour;

  static const double _r = 5;

  @override
  void paint(Canvas canvas, Size size) {
    final rr = RRect.fromRectAndCorners(
      Offset.zero & size,
      topLeft: const Radius.circular(_r),
      topRight: const Radius.circular(_r),
    );
    if (stubbed) {
      canvas.drawRRect(rr, Paint()..color = stub);
      return;
    }
    canvas.save();
    canvas.clipRRect(rr);
    var y = size.height;
    for (var i = 0; i < colours.length; i++) {
      final h = size.height * shares[i];
      if (h <= 0) continue;
      canvas.drawRect(
        Rect.fromLTWH(0, y - h, size.width, h),
        Paint()..color = colours[i],
      );
      y -= h;
    }
    canvas.restore();
    if (outline == LoadBarOutline.none) return;
    final stroke = Paint()
      ..color = outlineColour
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final inset = rr.deflate(1);
    if (outline == LoadBarOutline.solid) {
      canvas.drawRRect(inset, stroke);
    } else {
      final path = Path()..addRRect(inset);
      for (final m in path.computeMetrics()) {
        var d = 0.0;
        while (d < m.length) {
          canvas.drawPath(m.extractPath(d, math.min(d + 5, m.length)), stroke);
          d += 9;
        }
      }
    }
  }

  @override
  bool shouldRepaint(_BarPainter o) =>
      o.colours != colours ||
      o.shares != shares ||
      o.outline != outline ||
      o.stubbed != stubbed;
}

class _UsualLine extends CustomPainter {
  _UsualLine({
    required this.y,
    required this.x0,
    required this.x1,
    required this.colour,
  });
  final double y;
  final double x0;
  final double x1;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = colour
      ..strokeWidth = 1.5;
    for (var x = x0; x < x1; x += 8) {
      canvas.drawLine(Offset(x, y), Offset(math.min(x + 4, x1), y), p);
    }
  }

  @override
  bool shouldRepaint(_UsualLine o) =>
      o.y != y || o.x0 != x0 || o.x1 != x1 || o.colour != colour;
}
