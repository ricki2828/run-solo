import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../platform/gateway.dart' show Units;
import '../theme/theme.dart';
import 'chrome.dart';

/// Run detail's elevation card: climb and descent, the profile against
/// distance, and the run's true pace (an estimate). Same chart style as
/// Trends (tokens only, faint grid, labels in the right gutter).
///
/// Tap or drag along the profile to read a point (distance, height, grade);
/// [onScrub] hears it, null when the selection clears.
// TODO(elevation-map): the Google map is a platform view behind the
// MapSurfaceFactory seam, which has no "highlight this point" call. When it
// gets one, run detail passes [onScrub]'s point (ElevPoint.tMs -> the sample's
// lat/lon) through it so the dot moves on the route.
class ElevationProfile extends StatefulWidget {
  const ElevationProfile({
    super.key,
    required this.elevation,
    required this.units,
    this.truePaceSecPerKm,
    this.onScrub,
  });

  final engine.RunElevation elevation;

  /// The run's true pace (hills and heat taken out); null shows no tile.
  final double? truePaceSecPerKm;
  final Units units;
  final ValueChanged<engine.ElevPoint?>? onScrub;

  static const double kHeight = 160;

  @override
  State<ElevationProfile> createState() => _ElevationProfileState();
}

class _ElevationProfileState extends State<ElevationProfile> {
  engine.ElevPoint? _selected;

  void _select(engine.ElevPoint? p) {
    if (p == _selected) return;
    setState(() => _selected = p);
    widget.onScrub?.call(p);
  }

  engine.ElevPoint _at(double dx, double plotW) {
    final pts = widget.elevation.points;
    final total = pts.last.distM;
    final frac = (dx / plotW).clamp(0.0, 1.0);
    return widget.elevation.nearest(frac * total);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final e = widget.elevation;
    final units = widget.units;
    final gps = e.src == engine.ElevSource.gps;
    final sel = _selected;
    final truePace = widget.truePaceSecPerKm;
    return Container(
      key: const ValueKey('elevation-card'),
      decoration: BoxDecoration(
        color: t.bgRaised,
        border: Border.all(color: t.lineHair),
        borderRadius: BorderRadius.circular(Radii.card),
      ),
      padding: const EdgeInsets.all(Space.x16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ELEVATION',
            style: RunSoloType.heading19.copyWith(color: t.inkPrimary),
          ),
          const SizedBox(height: Space.x12),
          Wrap(
            spacing: Space.x24,
            runSpacing: Space.x12,
            children: [
              StatTile(
                key: const ValueKey('elevation-climb'),
                label: 'climb',
                value: Fmt.elevation(e.ascentM, units),
                size: 28,
              ),
              StatTile(
                key: const ValueKey('elevation-descent'),
                label: 'descent',
                value: Fmt.elevation(e.descentM, units),
                size: 28,
              ),
              if (truePace != null)
                StatTile(
                  key: const ValueKey('elevation-gap'),
                  label: 'true pace (estimate)',
                  value: Fmt.paceUnit(truePace, units),
                  size: 28,
                ),
            ],
          ),
          const SizedBox(height: Space.x16),
          SizedBox(
            height: RunSoloType.micro11.fontSize! * 1.6,
            child: Text(
              sel == null
                  ? 'Tap or drag the profile to read a point.'
                  : '${Fmt.distance(sel.distM, units)} · '
                        '${Fmt.elevation(sel.elevM, units)} · '
                        'grade ${Fmt.grade(sel.grade == null ? null : sel.grade! * 100)}',
              key: const ValueKey('elevation-callout'),
              style: RunSoloType.micro11.copyWith(
                color: sel == null ? t.inkSecondary : t.inkPrimary,
              ),
            ),
          ),
          Semantics(
            label:
                'Elevation profile. Climb ${Fmt.elevation(e.ascentM, units)}, '
                'descent ${Fmt.elevation(e.descentM, units)}.',
            child: LayoutBuilder(
              builder: (context, box) {
                final plotW = box.maxWidth - _ProfilePainter.gutter;
                return GestureDetector(
                  key: const ValueKey('elevation-chart'),
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) {
                    final p = _at(d.localPosition.dx, plotW);
                    _select(p == _selected ? null : p);
                  },
                  onHorizontalDragStart: (d) =>
                      _select(_at(d.localPosition.dx, plotW)),
                  onHorizontalDragUpdate: (d) =>
                      _select(_at(d.localPosition.dx, plotW)),
                  child: SizedBox(
                    height: ElevationProfile.kHeight,
                    width: double.infinity,
                    child: CustomPaint(
                      painter: _ProfilePainter(
                        elevation: e,
                        units: units,
                        selected: sel,
                        tokens: t,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: Space.x8),
          Text(
            gps
                ? 'From GPS altitude, so rougher. This phone has no barometer.'
                : "Measured with your phone's barometer, level set by GPS.",
            key: const ValueKey('elevation-source'),
            style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
          ),
        ],
      ),
    );
  }
}

class _ProfilePainter extends CustomPainter {
  _ProfilePainter({
    required this.elevation,
    required this.units,
    required this.selected,
    required this.tokens,
  });

  final engine.RunElevation elevation;
  final Units units;
  final engine.ElevPoint? selected;
  final RunSoloTokens tokens;

  static const double gutter = 56;
  static const double _top = 8;
  static const double _bottom = 22;

  /// A flat run still gets this much vertical room, so a 3 m wobble does not
  /// draw as a mountain.
  static const double _minSpanM = 20;

  TextPainter _tp(String s, Color c, {TextAlign align = TextAlign.left}) =>
      TextPainter(
        text: TextSpan(
          text: s,
          style: RunSoloType.micro11.copyWith(color: c),
        ),
        textDirection: TextDirection.ltr,
        textAlign: align,
      )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    final pts = elevation.points;
    final plotW = size.width - gutter;
    final bottom = size.height - _bottom;
    final totalM = pts.last.distM;
    if (totalM <= 0) return;
    var lo = elevation.minElevM;
    var hi = elevation.maxElevM;
    if (hi - lo < _minSpanM) {
      final mid = (hi + lo) / 2;
      lo = mid - _minSpanM / 2;
      hi = mid + _minSpanM / 2;
    }
    final pad = (hi - lo) * 0.08;
    lo -= pad;
    hi += pad;
    double x(double d) => plotW * d / totalM;
    double y(double e) => bottom - (bottom - _top) * (e - lo) / (hi - lo);

    // Faint grid with gutter labels (heights in the run's units).
    final grid = Paint()
      ..color = tokens.lineHair
      ..strokeWidth = 1;
    final step = _niceStep((hi - lo) / 3);
    for (var v = (lo / step).ceil() * step; v <= hi; v += step) {
      final yy = y(v);
      if (yy > bottom - 4 || yy < _top) continue;
      canvas.drawLine(Offset(0, yy), Offset(plotW, yy), grid);
      final tp = _tp(Fmt.elevation(v, units), tokens.inkMuted);
      tp.paint(canvas, Offset(plotW + 6, yy - tp.height / 2));
    }
    canvas.drawLine(
      Offset(0, bottom),
      Offset(plotW, bottom),
      Paint()
        ..color = tokens.inkMuted
        ..strokeWidth = 1,
    );

    // Distance axis: 0, then round steps of the run's own unit.
    final unitM = units == Units.mi ? 1609.344 : 1000.0;
    final unitLabel = units == Units.mi ? 'mi' : 'km';
    final totalU = totalM / unitM;
    final xs = _niceStep(totalU / 4);
    for (var u = 0.0; u <= totalU + 1e-9; u += xs) {
      final tp = _tp(u == 0 ? '0' : '${_trim(u)} $unitLabel', tokens.inkMuted);
      final xx = x(u * unitM);
      final left = (xx - tp.width / 2).clamp(0.0, plotW - tp.width);
      tp.paint(canvas, Offset(left, bottom + 5));
    }

    // The profile: an area under the line, then the line.
    final line = Path();
    final area = Path()..moveTo(x(pts.first.distM), bottom);
    for (var i = 0; i < pts.length; i++) {
      final p = Offset(x(pts[i].distM), y(pts[i].elevM));
      if (i == 0) {
        line.moveTo(p.dx, p.dy);
      } else {
        line.lineTo(p.dx, p.dy);
      }
      area.lineTo(p.dx, p.dy);
    }
    area
      ..lineTo(x(pts.last.distM), bottom)
      ..close();
    canvas.drawPath(
      area,
      Paint()..color = tokens.inkPrimary.withValues(alpha: 0.08),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = tokens.inkPrimary
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );

    final s = selected;
    if (s != null) {
      final sx = x(s.distM);
      canvas.drawLine(
        Offset(sx, _top),
        Offset(sx, bottom),
        Paint()
          ..color = tokens.inkMuted
          ..strokeWidth = 1,
      );
      canvas.drawCircle(
        Offset(sx, y(s.elevM)),
        5,
        Paint()..color = tokens.accentArc,
      );
    }
  }

  static String _trim(double v) =>
      v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);

  /// 1, 2, 5, 10 ... times a power of ten, at least [raw].
  static double _niceStep(double raw) {
    if (raw <= 0) return 1;
    final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    for (final m in [1.0, 2.0, 5.0, 10.0]) {
      if (m * mag >= raw) return m * mag;
    }
    return 10 * mag;
  }

  @override
  bool shouldRepaint(_ProfilePainter old) =>
      old.elevation != elevation ||
      old.units != units ||
      old.selected != selected ||
      old.tokens != tokens;
}
