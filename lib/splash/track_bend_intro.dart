/// "Track Bend" intro (brand direction C): on the light ground the five lanes
/// of a 400 m bend draw on round the bend, outer Z1 leading and the inner
/// lanes chasing on a stagger. The first launch of each version then sets the
/// wordmark under the mark and draws its five zone stripes left to right;
/// everything exits over Home. The short version draws only the mark. Vector
/// only: the paths are the production outlines in
/// `lib/brand/track_bend_paths.dart`.
library;

import 'package:flutter/material.dart';

import '../brand/track_bend.dart';
import '../brand/track_bend_paths.dart';
import '../theme/theme.dart';
import 'intro_gate.dart';

/// Beat timings, ms.
abstract final class TrackBendBeats {
  static const int fadeInEnd = 120;

  /// Lane `k` starts at [laneStart] + k * [laneStep] and takes [laneMs].
  static const int laneStart = 60;
  static const int laneStep = 40;
  static const int laneMs = 380;

  static const int wordStart = 560;
  static const int wordEnd = 800;

  /// Stripe `k` starts at [stripeStart] + k * [stripeStep] and takes
  /// [stripeMs], left to right.
  static const int stripeStart = 680;
  static const int stripeStep = 40;
  static const int stripeMs = 240;

  static const int fullExitStart = 1100;
  static const int fullEnd = 1400;

  static const int shortLaneStart = 20;
  static const int shortLaneStep = 30;
  static const int shortLaneMs = 240;
  static const int shortDrawEnd = 400;
  static const int shortEnd = 600;

  static const int skipFadeMs = 160;
  static const int reducedHoldMs = 300;

  static int total(IntroKind kind) =>
      kind == IntroKind.full ? fullEnd : shortEnd;

  /// The last frame before the exit beat: what reduced motion shows and
  /// what a skip fades out from.
  static int finalFrame(IntroKind kind) =>
      kind == IntroKind.full ? fullExitStart : shortDrawEnd;
}

/// Everything the painter needs at one instant.
@immutable
class TrackBendFrame {
  const TrackBendFrame({
    required this.opacity,
    required this.scale,
    required this.lanes,
    required this.wordOpacity,
    required this.wordDy,
    required this.stripes,
  });

  /// Whole composition (fade in, exit fade).
  final double opacity;

  /// Whole composition about the mark's centre (exit 1.0 to 0.96).
  final double scale;

  /// How much of each lane is drawn, Z1 first, 0..1.
  final List<double> lanes;

  final double wordOpacity;
  final double wordDy;

  /// How much of each wordmark stripe is drawn, left to right, 0..1.
  final List<double> stripes;
}

/// Where the mark and wordmark sit on a screen: the mark 56 % of the width
/// wide, centred at 40 % of the height; the wordmark 62 % of the width wide,
/// 36 dp under the mark.
@immutable
class TrackBendLayout {
  factory TrackBendLayout(Size size) {
    final w = size.width;
    final s = 0.56 * w / TrackBendGeometry.markWidth;
    final markH = TrackBendGeometry.markHeight * s;
    final origin = Offset(
      (w - TrackBendGeometry.markWidth * s) / 2,
      0.40 * size.height - markH / 2,
    );
    final wordW = TrackBendGeometry.wordRight - TrackBendGeometry.wordLeft;
    final ws = 0.62 * w / wordW;
    return TrackBendLayout._(
      size: size,
      s: s,
      origin: origin,
      ws: ws,
      wordOrigin: Offset(
        (w - 0.62 * w) / 2 - TrackBendGeometry.wordLeft * ws,
        origin.dy + markH + 36 - TrackBendGeometry.wordTop * ws,
      ),
    );
  }

  const TrackBendLayout._({
    required this.size,
    required this.s,
    required this.origin,
    required this.ws,
    required this.wordOrigin,
  });

  final Size size;

  /// Mark units to pixels, and the mark's top left.
  final double s;
  final Offset origin;

  /// Font units to pixels for the wordmark, and its origin.
  final double ws;
  final Offset wordOrigin;

  Offset get markCentre => Offset(
    origin.dx + TrackBendGeometry.markWidth / 2 * s,
    origin.dy + TrackBendGeometry.markHeight / 2 * s,
  );
}

double _seg(double t, num a, num b) => ((t - a) / (b - a)).clamp(0.0, 1.0);

double _lerp(double a, double b, double p) => a + (b - a) * p;

List<double> _lanesAt(double ms, int start, int step, int dur) => [
  for (var k = 0; k < TrackBendGeometry.laneCount; k++)
    MotionCurves.emphasized.transform(
      _seg(ms, start + k * step, start + k * step + dur),
    ),
];

/// The frame at [ms] (pure, so tests pin the beats).
TrackBendFrame trackBendFrameAt(IntroKind kind, double ms) {
  final fadeIn = MotionCurves.standard.transform(
    _seg(ms, 0, TrackBendBeats.fadeInEnd),
  );
  const none = [0.0, 0.0, 0.0, 0.0, 0.0];
  if (kind == IntroKind.full) {
    final exit = MotionCurves.exit.transform(
      _seg(ms, TrackBendBeats.fullExitStart, TrackBendBeats.fullEnd),
    );
    final word = MotionCurves.standard.transform(
      _seg(ms, TrackBendBeats.wordStart, TrackBendBeats.wordEnd),
    );
    return TrackBendFrame(
      opacity: fadeIn * (1 - exit),
      scale: _lerp(1, 0.96, exit),
      lanes: _lanesAt(
        ms,
        TrackBendBeats.laneStart,
        TrackBendBeats.laneStep,
        TrackBendBeats.laneMs,
      ),
      wordOpacity: word,
      wordDy: 8 * (1 - word),
      stripes: _lanesAt(
        ms,
        TrackBendBeats.stripeStart,
        TrackBendBeats.stripeStep,
        TrackBendBeats.stripeMs,
      ),
    );
  }
  // 0.6 s: the lanes only, no wordmark.
  final exit = MotionCurves.exit.transform(
    _seg(ms, TrackBendBeats.shortDrawEnd, TrackBendBeats.shortEnd),
  );
  return TrackBendFrame(
    opacity: fadeIn * (1 - exit),
    scale: _lerp(1, 0.96, exit),
    lanes: _lanesAt(
      ms,
      TrackBendBeats.shortLaneStart,
      TrackBendBeats.shortLaneStep,
      TrackBendBeats.shortLaneMs,
    ),
    wordOpacity: 0,
    wordDy: 0,
    stripes: none,
  );
}

class TrackBendPainter extends CustomPainter {
  TrackBendPainter({
    required this.frame,
    required this.layout,
    required this.ink,
    required this.colors,
  });

  final TrackBendFrame frame;
  final TrackBendLayout layout;
  final Color ink;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final f = frame;
    if (f.opacity <= 0) return;
    final l = layout;
    final c = l.markCentre;
    canvas
      ..save()
      ..translate(c.dx, c.dy)
      ..scale(f.scale)
      ..translate(-c.dx, -c.dy)
      ..save()
      ..translate(l.origin.dx, l.origin.dy)
      ..scale(l.s);
    paintTrackBendLanes(
      canvas,
      colors: colors,
      progress: f.lanes,
      opacity: f.opacity,
    );
    canvas.restore();
    if (f.wordOpacity > 0) {
      canvas
        ..save()
        ..translate(l.wordOrigin.dx, l.wordOrigin.dy + f.wordDy)
        ..scale(l.ws);
      paintTrackBendWordmark(
        canvas,
        ink: ink,
        colors: colors,
        stripes: f.stripes,
        opacity: f.opacity * f.wordOpacity,
      );
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(TrackBendPainter old) =>
      old.frame != frame ||
      old.layout.size != layout.size ||
      old.ink != ink ||
      old.colors != colors;
}

/// Plays one intro over the app and calls [onDone] when it has faded out.
/// Tap anywhere skips to a 160 ms exit. Reduced motion: the final frame for
/// 300 ms, then a cut. Silent: no haptic, no sound.
class TrackBendIntro extends StatefulWidget {
  const TrackBendIntro({
    super.key,
    required this.kind,
    required this.onDone,
    this.reducedMotion = false,
  });

  final IntroKind kind;
  final VoidCallback onDone;
  final bool reducedMotion;

  @override
  State<TrackBendIntro> createState() => _TrackBendIntroState();
}

class _TrackBendIntroState extends State<TrackBendIntro>
    with TickerProviderStateMixin {
  late final AnimationController _play;
  AnimationController? _skip;
  double? _skippedAt;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    final total = widget.reducedMotion
        ? TrackBendBeats.reducedHoldMs
        : TrackBendBeats.total(widget.kind);
    _play =
        AnimationController(
            vsync: this,
            duration: Duration(milliseconds: total),
          )
          ..addListener(() => setState(() {}))
          ..addStatusListener((s) {
            if (s == AnimationStatus.completed) _finish();
          })
          ..forward();
  }

  void _finish() {
    if (_done) return;
    _done = true;
    widget.onDone();
  }

  void _onTap() {
    if (_skip != null || _done) return;
    _play.stop();
    _skippedAt = TrackBendBeats.finalFrame(widget.kind).toDouble();
    _skip =
        AnimationController(
            vsync: this,
            duration: const Duration(milliseconds: TrackBendBeats.skipFadeMs),
          )
          ..addListener(() => setState(() {}))
          ..addStatusListener((s) {
            if (s == AnimationStatus.completed) _finish();
          })
          ..forward();
  }

  @override
  void dispose() {
    _play.dispose();
    _skip?.dispose();
    super.dispose();
  }

  TrackBendFrame _frame() {
    if (widget.reducedMotion) {
      // Static final frame, then a cut (no fade).
      return trackBendFrameAt(
        widget.kind,
        TrackBendBeats.finalFrame(widget.kind).toDouble(),
      );
    }
    final skip = _skip;
    if (skip != null) {
      final f = trackBendFrameAt(widget.kind, _skippedAt!);
      final p = MotionCurves.exit.transform(skip.value);
      return TrackBendFrame(
        opacity: f.opacity * (1 - p),
        scale: 1 - 0.04 * p,
        lanes: f.lanes,
        wordOpacity: f.wordOpacity,
        wordDy: f.wordDy,
        stripes: f.stripes,
      );
    }
    return trackBendFrameAt(
      widget.kind,
      _play.value * TrackBendBeats.total(widget.kind),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final brightness = Theme.of(context).brightness;
    return LayoutBuilder(
      builder: (context, box) {
        final l = TrackBendLayout(box.biggest);
        final f = _frame();
        // The ground is solid until the exit beat (the system splash is the
        // same colour), then fades with the composition, revealing Home.
        final ground = widget.reducedMotion || _skip != null
            ? f.opacity
            : _groundOpacity();
        return GestureDetector(
          key: const ValueKey('track-bend-intro'),
          behavior: HitTestBehavior.opaque,
          onTap: _onTap,
          child: Semantics(
            label: 'Run Supreme',
            child: ColoredBox(
              color: t.bgBase.withValues(alpha: ground.clamp(0.0, 1.0)),
              child: CustomPaint(
                size: box.biggest,
                painter: TrackBendPainter(
                  frame: f,
                  layout: l,
                  ink: t.inkPrimary,
                  colors: trackBendColors(brightness),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  double _groundOpacity() {
    final ms = _play.value * TrackBendBeats.total(widget.kind);
    final start = widget.kind == IntroKind.full
        ? TrackBendBeats.fullExitStart
        : TrackBendBeats.shortDrawEnd;
    final p = MotionCurves.exit.transform(
      _seg(ms, start, TrackBendBeats.total(widget.kind)),
    );
    return 1 - p;
  }
}
