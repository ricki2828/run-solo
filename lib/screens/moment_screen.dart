import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../share/share_card.dart';
import '../share/share_card_sheet.dart';
import '../state/progress_snapshot.dart';
import '../theme/caps_text.dart';
import '../theme/lanes.dart';
import '../theme/theme.dart';
import '../widgets/chrome.dart';

/// The flat colour behind a moment: its lane, else one brand colour by kind.
Color momentColour(RunSoloTokens t, Moment m) {
  // A personal best is always cyan (PB meaning), whatever lane it came from.
  if (m.kind == MomentKind.pb) return t.accentArc;
  final lane = m.lane;
  if (lane != null) return t.laneFill(lane);
  return switch (m.kind) {
    MomentKind.first => t.typeGoal,
    MomentKind.pb => t.accentArc,
    MomentKind.levelUp => t.typeTests,
    MomentKind.story => t.typeIntervals,
    MomentKind.quest => t.typeTrail,
  };
}

/// [big] with every digit run counted up from zero by [t] (0..1). Runs keep
/// their final width (zero padded), so the figure never reflows; at 1 it is
/// exactly [big].
String countUpFigure(String big, double t) {
  if (t >= 1) return big;
  return big.replaceAllMapped(RegExp(r'\d+'), (m) {
    final end = int.parse(m[0]!);
    final v = (end * t).floor();
    return v.toString().padLeft(m[0]!.length, '0');
  });
}

/// The band of the screen the text lives in; rays and confetti stay out of it.
Rect momentSafeZone(Size size) =>
    Rect.fromLTRB(0, size.height * 0.27, size.width, size.height * 0.64);

/// Shows [moment] full screen. Rare by design: callers pass at most one.
Future<void> showMoment(BuildContext context, Moment moment) =>
    Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 220),
        reverseTransitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (_, _, _) => MomentScreen(moment: moment),
        transitionsBuilder: (_, a, _, child) =>
            FadeTransition(opacity: a, child: child),
      ),
    );

/// A full-screen reveal for a [Moment]: flat colour, eyebrow, a huge
/// condensed figure, one detail line, "Nice" and "Share". One entrance
/// (figure scales and fades in, soft rays and confetti settle); with reduced
/// motion it simply appears.
class MomentScreen extends StatefulWidget {
  const MomentScreen({super.key, required this.moment, this.onShare});
  final Moment moment;

  /// Overrides the share flow (tests); default opens the share-card sheet.
  final VoidCallback? onShare;

  @override
  State<MomentScreen> createState() => _MomentScreenState();
}

class _MomentScreenState extends State<MomentScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.of(context).disableAnimations) {
      _c.value = 1;
    } else {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _share(Color fill) {
    final m = widget.moment;
    if (widget.onShare != null) return widget.onShare!();
    showShareCardSheet(
      context,
      data: MomentCardData(
        eyebrow: m.eyebrow,
        big: m.big,
        detail: shareSafeMomentDetail(m.detail),
        colour: fill,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final m = widget.moment;
    final fill = momentColour(t, m);
    final ink = readableOn(fill);
    Animation<double> beat(double a, double b, [Curve c = Curves.easeOut]) =>
        CurvedAnimation(
          parent: _c,
          curve: Interval(a, b, curve: c),
        );
    final figure = beat(0.08, 0.6, Curves.easeOutBack);
    final figureFade = beat(0.08, 0.35);
    final count = beat(0.12, 0.7, Curves.easeOutCubic);
    final rest = beat(0.45, 0.85);
    return Scaffold(
      key: ValueKey('moment-${m.id}'),
      backgroundColor: fill,
      body: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _c,
                builder: (_, _) => CustomPaint(
                  painter: _BurstPainter(
                    progress: _c.value,
                    ink: ink,
                    fill: fill,
                    confetti: m.kind != MomentKind.story,
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.screenGutter,
                Space.x24,
                Space.screenGutter,
                Space.x24,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Spacer(flex: 3),
                  FadeTransition(
                    opacity: rest,
                    child: Text(
                      m.eyebrow.toUpperCase(),
                      key: const ValueKey('moment-eyebrow'),
                      textAlign: TextAlign.center,
                      style: RunSoloType.runLabel.copyWith(color: ink),
                    ),
                  ),
                  const SizedBox(height: Space.x12),
                  FadeTransition(
                    opacity: figureFade,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.6, end: 1).animate(figure),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: AnimatedBuilder(
                          animation: count,
                          builder: (_, _) => Text(
                            countUpFigure(m.big.toUpperCase(), count.value),
                            key: const ValueKey('moment-big'),
                            maxLines: 1,
                            textAlign: TextAlign.center,
                            style: RunSoloType.display96.copyWith(
                              fontSize: 220,
                              color: ink,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: Space.x16),
                  FadeTransition(
                    opacity: rest,
                    child: Text(
                      m.detail,
                      key: const ValueKey('moment-detail'),
                      textAlign: TextAlign.center,
                      style: RunSoloType.body17.copyWith(
                        color: ink,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const Spacer(flex: 4),
                  FadeTransition(
                    opacity: rest,
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            key: const ValueKey('moment-nice'),
                            // Same height as Share, 2 dp outline, 16 sp
                            // label (ui review 24-Oct #19). Not RunButton:
                            // its raised ground would not sit on the flood.
                            style: OutlinedButton.styleFrom(
                              foregroundColor: ink,
                              minimumSize: const Size.fromHeight(
                                RunButton.height,
                              ),
                              side: BorderSide(color: ink, width: 2),
                              textStyle: RunSoloType.title28.copyWith(
                                fontSize: 16,
                              ),
                            ),
                            onPressed: () => Navigator.of(context).maybePop(),
                            child: const CapsText('Nice'),
                          ),
                        ),
                        const SizedBox(width: Space.x12),
                        Expanded(
                          child: FilledButton(
                            key: const ValueKey('moment-share'),
                            style: FilledButton.styleFrom(
                              backgroundColor: ink,
                              foregroundColor: fill,
                            ),
                            onPressed: () => _share(fill),
                            child: const CapsText('Share'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The entrance: a darker ground swept away by a circle of the moment's
/// colour, a shock ring, soft rays and confetti that settle. Rays, ring and
/// confetti fade out softly over [momentSafeZone], so text sits on flat colour. Seeded:
/// the settled frame is identical every time.
class _BurstPainter extends CustomPainter {
  _BurstPainter({
    required this.progress,
    required this.ink,
    required this.fill,
    required this.confetti,
  });
  final double progress;
  final Color ink;
  final Color fill;
  final bool confetti;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height * 0.42);
    // Colour sweep: dark ground, the moment colour grows out of the centre.
    final sweep = Curves.easeOutCubic.transform(math.min(1, progress / 0.4));
    if (sweep < 1) {
      canvas
        ..drawRect(
          Offset.zero & size,
          Paint()
            ..color = HSLColor.fromColor(fill)
                .withLightness(HSLColor.fromColor(fill).lightness * 0.55)
                .toColor(),
        )
        ..drawCircle(
          centre,
          size.longestSide * 1.1 * sweep,
          Paint()..color = fill,
        );
    }
    final safe = momentSafeZone(size);
    // Rays, ring and confetti draw into a layer that an elliptical fade then
    // thins to nothing over the text band, so there is no hard edge.
    canvas.saveLayer(Offset.zero & size, Paint());
    final fade = Curves.easeOut.transform(math.min(1, progress * 2));
    final rays = Paint()..color = ink.withValues(alpha: 0.12 * fade);
    const n = 14;
    final r = size.longestSide;
    for (var i = 0; i < n; i++) {
      final a = (i / n) * math.pi * 2 + progress * 0.25;
      const w = math.pi / n * 0.55;
      canvas.drawPath(
        Path()
          ..moveTo(centre.dx, centre.dy)
          ..lineTo(
            centre.dx + r * math.cos(a - w),
            centre.dy + r * math.sin(a - w),
          )
          ..lineTo(
            centre.dx + r * math.cos(a + w),
            centre.dy + r * math.sin(a + w),
          )
          ..close(),
        rays,
      );
    }
    // One shock ring that leaves the screen early.
    final ringT = math.min(1.0, progress / 0.55);
    if (ringT < 1) {
      canvas.drawCircle(
        centre,
        size.longestSide * 0.9 * Curves.easeOut.transform(ringT),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 10 * (1 - ringT) + 2
          ..color = ink.withValues(alpha: 0.5 * (1 - ringT)),
      );
    }
    if (confetti) {
      final rnd = math.Random(11);
      final fall = Curves.easeOutCubic.transform(progress);
      for (var i = 0; i < 36; i++) {
        final x = rnd.nextDouble() * size.width;
        final y0 = -40.0 - rnd.nextDouble() * 120;
        final y1 = rnd.nextDouble() * size.height;
        final s = 6 + rnd.nextDouble() * 8;
        final rot = rnd.nextDouble() * math.pi + progress * 2;
        final y = y0 + (y1 - y0) * fall;
        // Resting pieces never land in the text band (clip handles the fall).
        canvas
          ..save()
          ..translate(x, y)
          ..rotate(rot)
          ..drawRect(
            Rect.fromCenter(center: Offset.zero, width: s, height: s * 0.6),
            Paint()..color = ink.withValues(alpha: i.isEven ? 0.55 : 0.3),
          )
          ..restore();
      }
    }
    // Soft mask: clear (alpha 0) through the whole text band, easing back to
    // full strength outside it. An ellipse around the band, not a box.
    final bandCentre = safe.center;
    final rx = safe.width * 0.85;
    final ry = safe.height * 0.85;
    final mask = Paint()
      ..blendMode = BlendMode.dstIn
      ..shader = ui.Gradient.radial(
        Offset.zero,
        1,
        [
          ink.withValues(alpha: 0),
          ink.withValues(alpha: 0),
          ink.withValues(alpha: 1),
        ],
        const [0, 0.9, 1.35],
        TileMode.clamp,
        Matrix4.translationValues(
          bandCentre.dx,
          bandCentre.dy,
          0,
        ).multiplied(Matrix4.diagonal3Values(rx, ry, 1)).storage,
      );
    canvas
      ..drawRect(Offset.zero & size, mask)
      ..restore();
  }

  @override
  bool shouldRepaint(_BurstPainter old) =>
      old.progress != progress || old.ink != ink || old.fill != fill;
}
