import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../share/share_card.dart';
import '../share/share_card_sheet.dart';
import '../state/progress_snapshot.dart';
import '../theme/lanes.dart';
import '../theme/theme.dart';

/// The flat colour behind a moment: its lane, else one brand colour by kind.
Color momentColour(RunSoloTokens t, Moment m) {
  final lane = m.lane;
  if (lane != null) return t.laneFill(lane);
  return switch (m.kind) {
    MomentKind.first => t.typeGoal,
    MomentKind.pb => t.typeLaps,
    MomentKind.levelUp => t.typeTests,
    MomentKind.story => t.typeIntervals,
  };
}

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
                      style: RunSoloType.runLabel.copyWith(
                        color: ink.withValues(alpha: 0.85),
                      ),
                    ),
                  ),
                  const SizedBox(height: Space.x12),
                  FadeTransition(
                    opacity: figureFade,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.6, end: 1).animate(figure),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          m.big.toUpperCase(),
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
                  const SizedBox(height: Space.x16),
                  FadeTransition(
                    opacity: rest,
                    child: Text(
                      m.detail,
                      key: const ValueKey('moment-detail'),
                      textAlign: TextAlign.center,
                      style: RunSoloType.body17.copyWith(color: ink),
                    ),
                  ),
                  const Spacer(flex: 4),
                  FadeTransition(
                    opacity: rest,
                    child: Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            key: const ValueKey('moment-nice'),
                            style: FilledButton.styleFrom(
                              backgroundColor: ink,
                              foregroundColor: fill,
                            ),
                            onPressed: () => Navigator.of(context).maybePop(),
                            child: const Text('Nice'),
                          ),
                        ),
                        const SizedBox(width: Space.x12),
                        Expanded(
                          child: OutlinedButton(
                            key: const ValueKey('moment-share'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: ink,
                              side: BorderSide(color: ink, width: 1.5),
                            ),
                            onPressed: () => _share(fill),
                            child: const Text('Share'),
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

/// Soft rays behind the figure and a few confetti pieces that drift down
/// and rest. Seeded: the settled frame is identical every time.
class _BurstPainter extends CustomPainter {
  _BurstPainter({
    required this.progress,
    required this.ink,
    required this.confetti,
  });
  final double progress;
  final Color ink;
  final bool confetti;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height * 0.42);
    final fade = Curves.easeOut.transform(math.min(1, progress * 2));
    final rays = Paint()..color = ink.withValues(alpha: 0.07 * fade);
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
    if (!confetti) return;
    final rnd = math.Random(11);
    final fall = Curves.easeOutCubic.transform(progress);
    for (var i = 0; i < 26; i++) {
      final x = rnd.nextDouble() * size.width;
      final y0 = -40.0 - rnd.nextDouble() * 120;
      final y1 = rnd.nextDouble() * size.height;
      final s = 6 + rnd.nextDouble() * 8;
      final rot = rnd.nextDouble() * math.pi + progress * 2;
      final y = y0 + (y1 - y0) * fall;
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

  @override
  bool shouldRepaint(_BurstPainter old) =>
      old.progress != progress || old.ink != ink;
}
