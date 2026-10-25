import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../app/format.dart';
import '../platform/gateway.dart';
import '../theme/theme.dart';
import '../theme/zones.dart';
import 'chrome.dart' show RunSheetHeader;

/// One bar on [SplitsBars]: the label under it and its pace (s/km). A null
/// pace (a lap with no distance) leaves the slot empty. [readout] is the line
/// shown above the chart while the bar is selected ("km 3 · 6:00/km ·
/// +21 m"); [semantics] is what a screen reader says for it.
@immutable
class SplitBar {
  const SplitBar({
    required this.label,
    required this.paceSecPerKm,
    this.readout,
    this.semantics,
    this.zone,
  });
  final String label;
  final double? paceSecPerKm;

  /// The HR zone (1-5) the bar mostly ran in: its fill. Null without a
  /// heart rate (the bar takes [SplitsBars.noHrColor], never grey).
  final int? zone;
  final String? readout;
  final String? semantics;
}

/// Run detail's splits chart, in the leaderboard bar style
/// (`RecentBarsChart`): one vertical bar per km, mile or lap, taller =
/// faster, filled by the HR zone the split mostly ran in (the run-type colour
/// without a heart rate). A 4 px cap on each bar says faster or slower than
/// the run's median: mint, or vermillion, only beyond [noiseSec] (level bars
/// get none); the one unique fastest split is cyan, outlined and bold. Every bar carries its pace
/// above it (every second bar once they get too tight for it). Tap or drag
/// across the bars to pick one: it is outlined and its readout shows above
/// the chart. One legend line says which way is better; the info button
/// opens the full key (caps, outline, where the axis starts).
///
/// [truePace] only changes the wording: the caller passes True Pace values
/// when the run has them, and the chart says so.
class SplitsBars extends StatefulWidget {
  const SplitsBars({
    super.key,
    required this.bars,
    required this.units,
    required this.title,
    this.truePace = false,
    this.noHrColor,
  });

  final List<SplitBar> bars;
  final Units units;

  /// "KM SPLITS", "LAPS": the small caps line above the chart.
  final String title;
  final bool truePace;

  /// Bar colour for splits with no heart-rate zone: the run-type colour (Free =
  /// ice), never grey. Falls back to the muted ink when the caller has none.
  final Color Function(RunSoloTokens)? noHrColor;

  static const double kHeight = 160;

  /// The narrowest pace range the axis spans, s/km.
  static const double minSpanSec = 30;

  /// A split this far (s/km) off the median is faster or slower; closer is
  /// level. Roughly the GPS pace noise on a km.
  static const double noiseSec = 10;

  @override
  State<SplitsBars> createState() => _SplitsBarsState();
}

class _SplitsBarsState extends State<SplitsBars> {
  int? _selected;

  void _pick(double dx, double width, {bool toggle = false}) {
    final n = widget.bars.length;
    if (n == 0 || width <= 0) return;
    final i = (dx / (width / n)).floor().clamp(0, n - 1);
    if (widget.bars[i].paceSecPerKm == null) return;
    setState(() => _selected = toggle && _selected == i ? null : i);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final bars = widget.bars;
    final units = widget.units;
    final paces = [
      for (final b in bars)
        if (b.paceSecPerKm != null) b.paceSecPerKm!,
    ];
    if (paces.length < 2) return const SizedBox.shrink();
    final fastest = paces.reduce(math.min);
    final slowest = paces.reduce(math.max);
    final unit = units == Units.mi ? 'mi' : 'km';
    // The axis never spans less than [minSpanSec]: splits within GPS noise
    // of each other read as level, not as a collapse.
    final span = math.max(slowest - fastest, SplitsBars.minSpanSec);
    final base = fastest + span * 1.15;
    final top = fastest - span * 0.06;
    // Cyan means "best", so it needs a standout: the fastest split alone or
    // tied: a tie is not a standout, so it gets no cyan.
    final best = <int>{
      for (var i = 0; i < bars.length; i++)
        if (bars[i].paceSecPerKm != null &&
            bars[i].paceSecPerKm!.round() == fastest.round())
          i,
    };
    if (best.length > 1) best.clear();
    final sorted = [...paces]..sort();
    final median = sorted.length.isOdd
        ? sorted[sorted.length ~/ 2]
        : (sorted[sorted.length ~/ 2 - 1] + sorted[sorted.length ~/ 2]) / 2;
    final sel = _selected != null && _selected! < bars.length
        ? _selected
        : null;
    final readout = sel == null ? null : bars[sel].readout;
    return Column(
      key: const ValueKey('splits-bars'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.truePace ? '${widget.title} · TRUE PACE' : widget.title,
          style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
        ),
        const SizedBox(height: Space.x8),
        // Fixed height, so picking a bar never moves the chart.
        SizedBox(
          height: 22,
          child: Text(
            readout ?? 'Tap a bar to see its pace',
            key: const ValueKey('splits-readout'),
            style: RunSoloType.label13.copyWith(
              color: readout == null ? t.inkMuted : t.inkPrimary,
            ),
          ),
        ),
        LayoutBuilder(
          builder: (context, box) => GestureDetector(
            key: const ValueKey('splits-chart-area'),
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) =>
                _pick(d.localPosition.dx, box.maxWidth, toggle: true),
            onHorizontalDragStart: (d) =>
                _pick(d.localPosition.dx, box.maxWidth),
            onHorizontalDragUpdate: (d) =>
                _pick(d.localPosition.dx, box.maxWidth),
            child: SizedBox(
              height: SplitsBars.kHeight,
              width: double.infinity,
              child: CustomPaint(
                painter: _SplitsPainter(
                  bars: bars,
                  units: units,
                  best: best,
                  median: median,
                  selected: sel,
                  base: base,
                  top: top,
                  tokens: t,
                  brightness: Theme.of(context).brightness,
                  noHrColor: widget.noHrColor?.call(t),
                ),
              ),
            ),
          ),
        ),
        // One short legend line; the full key is behind the info button
        // (review #16), not a 3-line block under every chart.
        Row(
          children: [
            Expanded(
              child: Text(
                'Taller = faster',
                key: const ValueKey('splits-legend'),
                style: RunSoloType.label13.copyWith(color: t.inkSecondary),
              ),
            ),
            IconButton(
              key: const ValueKey('splits-legend-info'),
              tooltip: 'How to read this chart',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              icon: Icon(Icons.info_outline, color: t.inkSecondary, size: 20),
              onPressed: () => _showKey(
                context,
                'Taller is faster. Bars take the colour of the heart rate '
                'zone you ran in. A green cap is faster and a red cap slower '
                'than your median; the fastest is outlined. Fastest '
                '${Fmt.pace(fastest, units)}/$unit. The axis starts at '
                '${Fmt.pace(base, units)}/$unit.',
              ),
            ),
          ],
        ),
        if (widget.truePace) ...[
          const SizedBox(height: Space.x4),
          Text(
            'True pace takes hills and heat out. It is an estimate.',
            style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
          ),
        ],
      ],
    );
  }
}

void _showKey(BuildContext context, String text) {
  final t = Theme.of(context).extension<RunSoloTokens>()!;
  showModalBottomSheet<void>(
    context: context,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Space.screenGutter,
          Space.x16,
          Space.screenGutter,
          Space.x24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const RunSheetHeader(title: 'Reading the chart'),
            const SizedBox(height: Space.x8),
            Text(
              text,
              key: const ValueKey('splits-legend-full'),
              style: RunSoloType.body15.copyWith(color: t.inkPrimary),
            ),
          ],
        ),
      ),
    ),
  );
}

class _SplitsPainter extends CustomPainter {
  _SplitsPainter({
    required this.bars,
    required this.units,
    required this.best,
    required this.median,
    required this.selected,
    required this.base,
    required this.top,
    required this.tokens,
    required this.brightness,
    this.noHrColor,
  });
  final List<SplitBar> bars;
  final Units units;
  final Set<int> best;
  final double median;
  final int? selected;
  final double base;
  final double top;
  final RunSoloTokens tokens;
  final Brightness brightness;
  final Color? noHrColor;

  static const _topPad = 22.0, _bottomPad = 22.0;

  TextPainter _tp(
    String s,
    Color c, {
    FontWeight w = FontWeight.w500,
    double size = 11,
  }) => TextPainter(
    text: TextSpan(
      text: s,
      style: TextStyle(
        fontFamily: RunSoloType.ui,
        fontSize: size,
        fontWeight: w,
        color: c,
        fontFeatures: RunSoloType.tabular,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    final n = bars.length;
    if (n == 0) return;
    final bottom = size.height - _bottomPad;
    double y(double pace) =>
        bottom - (bottom - _topPad) * ((base - pace) / (base - top));
    final slot = size.width / n;
    final barW = math.min(24.0, slot * 0.6);
    final grid = Paint()
      ..color = tokens.lineHair
      ..strokeWidth = 1;
    for (var k = 1; k <= 3; k++) {
      final yy = bottom - (bottom - _topPad) * k / 3;
      canvas.drawLine(Offset(0, yy), Offset(size.width, yy), grid);
    }
    canvas.drawLine(
      Offset(0, bottom),
      Offset(size.width, bottom),
      Paint()
        ..color = tokens.inkMuted
        ..strokeWidth = 1,
    );
    // The pace above a bar and the number under it; once the bars get too
    // tight for the pace, every second one (the picked bar always).
    final paceW = _tp('00:00', tokens.inkSecondary, size: 12).width + 4;
    // Up to 12 bars every one is labelled; past that, every second or so.
    final paceStep = n <= 12 ? 1 : math.max(1, (paceW / slot).ceil());
    final numStep = math.max(1, (26 / slot).ceil());
    for (var i = 0; i < n; i++) {
      final p = bars[i].paceSecPerKm;
      if (p == null) continue;
      final x = i * slot + (slot - barW) / 2;
      final rect = Rect.fromLTRB(x, y(p), x + barW, bottom);
      final isSel = selected == i;
      if (isSel) {
        canvas.drawRect(
          Rect.fromLTRB(i * slot, _topPad - 4, (i + 1) * slot, bottom),
          Paint()..color = tokens.inkPrimary.withValues(alpha: 0.08),
        );
      }
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          rect,
          topLeft: const Radius.circular(3),
          topRight: const Radius.circular(3),
        ),
        Paint()
          ..color = bars[i].zone == null
              ? (noHrColor ?? tokens.inkMuted)
              : HrZones.distribution(bars[i].zone!, brightness),
      );
      if (best.contains(i)) {
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            rect.inflate(1),
            topLeft: const Radius.circular(4),
            topRight: const Radius.circular(4),
          ),
          Paint()
            ..color = tokens.accentArc
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
      // Cap: cyan for the unique best, else mint / vermillion beyond noise.
      final off = p - median;
      final cap = best.contains(i)
          ? tokens.accentArc
          : off <= -SplitsBars.noiseSec
          ? tokens.semImproving
          : off >= SplitsBars.noiseSec
          ? tokens.semSlower
          : null;
      if (cap != null) {
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTWH(x, rect.top, barW, math.min(4, rect.height)),
            topLeft: const Radius.circular(3),
            topRight: const Radius.circular(3),
          ),
          Paint()..color = cap,
        );
      }
      if (isSel) {
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            rect.inflate(2),
            topLeft: const Radius.circular(4),
            topRight: const Radius.circular(4),
          ),
          Paint()
            ..color = tokens.inkPrimary
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
      if (i % paceStep == 0 || isSel) {
        final hi = best.contains(i);
        final tp = _tp(
          Fmt.pace(p, units),
          isSel
              ? tokens.inkPrimary
              : (hi ? tokens.accentArc : tokens.inkSecondary),
          w: hi || isSel ? FontWeight.w700 : FontWeight.w500,
          size: 12,
        );
        final lx = (i * slot + slot / 2 - tp.width / 2).clamp(
          0.0,
          size.width - tp.width,
        );
        tp.paint(canvas, Offset(lx, y(p) - tp.height - (isSel ? 5 : 3)));
      }
    }
    for (var i = 0; i < n; i++) {
      final hi = best.contains(i) || selected == i;
      if (i % numStep != 0 && !hi) continue;
      final tp = _tp(
        bars[i].label,
        hi ? tokens.inkPrimary : tokens.inkSecondary,
        w: hi ? FontWeight.w700 : FontWeight.w500,
      );
      tp.paint(canvas, Offset(i * slot + slot / 2 - tp.width / 2, bottom + 5));
    }
  }

  /// One node per bar, full column wide and tall, for a screen reader.
  @override
  SemanticsBuilderCallback get semanticsBuilder => (size) {
    final n = bars.length;
    final slot = size.width / n;
    return [
      for (var i = 0; i < n; i++)
        if (bars[i].paceSecPerKm != null)
          CustomPainterSemantics(
            rect: Rect.fromLTWH(i * slot, 0, slot, size.height),
            properties: SemanticsProperties(
              label:
                  bars[i].semantics ??
                  '${bars[i].label}, ${Fmt.pace(bars[i].paceSecPerKm, units)}',
              selected: selected == i,
              textDirection: TextDirection.ltr,
            ),
          ),
    ];
  };

  @override
  bool shouldRepaint(_SplitsPainter old) =>
      old.bars != bars ||
      old.best != best ||
      old.median != median ||
      old.selected != selected ||
      old.base != base ||
      old.top != top ||
      old.tokens != tokens;
}
