/// "Lap Draw" intro (plan §4, brief A9): on black, the Arc lap line draws
/// across the screen and cuts the Lap Line R, the R settles, RUN SUPREME
/// fades up, then everything exits over Home. The 0.6 s version draws only
/// the mark's own line. Vector only: the outlines are the production paths
/// in `lib/brand/lap_line_paths.dart`.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../brand/lap_line_paths.dart';
import '../theme/theme.dart';
import 'intro_gate.dart';

/// Beat timings, ms (brief A9 tables).
abstract final class LapDrawBeats {
  static const int fadeInEnd = 150;
  static const int drawEnd = 650;
  static const int retractEnd = 850;
  static const int settleStart = 800;
  static const int settleEnd = 1050;
  static const int wordStart = 850;
  static const int wordEnd = 1100;
  static const int fullExitStart = 1150;
  static const int fullEnd = 1500;

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

/// Everything the painter needs at one instant, in screen pixels.
@immutable
class LapDrawFrame {
  const LapDrawFrame({
    required this.opacity,
    required this.scale,
    required this.markScale,
    required this.lineStart,
    required this.lineEnd,
    required this.lineThickness,
    required this.cutEnd,
    required this.cutThickness,
    required this.wordOpacity,
    required this.wordDy,
  });

  /// Whole composition (fade in, exit fade).
  final double opacity;

  /// Whole composition about the mark's centre (exit 1.0 → 0.96).
  final double scale;

  /// The R and its line about the R's centre (settle 1.04 → 1.0).
  final double markScale;

  /// Arc line from [lineStart] to [lineEnd] (x, layout space); empty when
  /// equal.
  final double lineStart;
  final double lineEnd;
  final double lineThickness;

  /// The cut is open from the left edge to [cutEnd] (x), [cutThickness] tall.
  final double cutEnd;
  final double cutThickness;

  final double wordOpacity;
  final double wordDy;
}

/// Where the mark and wordmark sit on a screen (brief A9 staging): R centred
/// at 42 % of the height and 40 % of the width tall; wordmark 24 dp below,
/// 64 % of the width wide.
@immutable
class LapDrawLayout {
  factory LapDrawLayout(Size size) {
    final w = size.width;
    final s = 0.40 * w / LapLineGeometry.cap;
    final markW = (LapLineGeometry.markTailEndX - LapLineGeometry.rLeft) * s;
    final ox = (w - markW) / 2 - LapLineGeometry.rLeft * s;
    final oy = 0.42 * size.height - LapLineGeometry.cap / 2 * s;
    final wordW = LapLineGeometry.wordRight - LapLineGeometry.wordLeft;
    final ws = 0.64 * w / wordW;
    final wordTop = oy + LapLineGeometry.cap * s + 24;
    return LapDrawLayout._(
      size: size,
      s: s,
      origin: Offset(ox, oy),
      ws: ws,
      wordOrigin: Offset(
        (w - 0.64 * w) / 2 - LapLineGeometry.wordLeft * ws,
        wordTop - LapLineGeometry.wordTop * ws,
      ),
    );
  }

  const LapDrawLayout._({
    required this.size,
    required this.s,
    required this.origin,
    required this.ws,
    required this.wordOrigin,
  });

  final Size size;

  /// Font units → pixels for the mark, and the mark's origin.
  final double s;
  final Offset origin;

  /// Font units → pixels for the wordmark, and its origin.
  final double ws;
  final Offset wordOrigin;

  double x(double fontX) => origin.dx + fontX * s;
  double get cutY => origin.dy + LapLineGeometry.cutY * s;
  double get rLeft => x(LapLineGeometry.rLeft);
  double get legEntry => x(LapLineGeometry.legEntryX);
  double get tailEnd => x(LapLineGeometry.markTailEndX);
  Offset get rCentre => Offset(
    x((LapLineGeometry.rLeft + LapLineGeometry.rRight) / 2),
    origin.dy + LapLineGeometry.cap / 2 * s,
  );
  double get markLine => LapLineGeometry.lineThickness * s;
  double get markCut => LapLineGeometry.cutThickness * s;
}

double _seg(double t, int a, int b) => ((t - a) / (b - a)).clamp(0.0, 1.0);

double _lerp(double a, double b, double p) => a + (b - a) * p;

/// The spring.sheet settle from 1.04 to 1.0, sampled at [ms] after its start.
double _settle(double ms) {
  final m = MotionSprings.sheet;
  final sim = SpringSimulation(
    SpringDescription(mass: m.mass, stiffness: m.stiffness, damping: m.damping),
    1.04,
    1.0,
    0,
  );
  return sim.x(ms / 1000);
}

/// The frame at [ms] (pure, so tests pin the beats). A 3 dp line draws
/// the full-width line; the mark's own line is the brand thickness.
LapDrawFrame lapDrawFrameAt(IntroKind kind, double ms, LapDrawLayout l) {
  final fadeIn = MotionCurves.standard.transform(
    _seg(ms, 0, LapDrawBeats.fadeInEnd),
  );
  if (kind == IntroKind.full) {
    const drawDp = 3.0;
    double head;
    double tail;
    double thick;
    if (ms < LapDrawBeats.fadeInEnd) {
      head = tail = 0;
      thick = drawDp;
    } else if (ms < LapDrawBeats.drawEnd) {
      final p = MotionCurves.emphasized.transform(
        _seg(ms, LapDrawBeats.fadeInEnd, LapDrawBeats.drawEnd),
      );
      tail = 0;
      head = _lerp(0, l.size.width, p);
      thick = drawDp;
    } else {
      final p = MotionCurves.standard.transform(
        _seg(ms, LapDrawBeats.drawEnd, LapDrawBeats.retractEnd),
      );
      tail = _lerp(0, l.legEntry, p);
      head = _lerp(l.size.width, l.tailEnd, p);
      thick = _lerp(drawDp, l.markLine, p);
    }
    // The cut opens behind the head: 80 ms from the head reaching the R.
    final reach = _headReachesMs(l);
    final cutP = reach == null ? 0.0 : ((ms - reach) / 80).clamp(0.0, 1.0);
    final exit = MotionCurves.exit.transform(
      _seg(ms, LapDrawBeats.fullExitStart, LapDrawBeats.fullEnd),
    );
    final word = MotionCurves.standard.transform(
      _seg(ms, LapDrawBeats.wordStart, LapDrawBeats.wordEnd),
    );
    return LapDrawFrame(
      opacity: fadeIn * (1 - exit),
      scale: _lerp(1, 0.96, exit),
      markScale: ms < LapDrawBeats.settleStart
          ? 1.04
          : ms >= LapDrawBeats.settleEnd
          ? 1.0
          : _settle(ms - LapDrawBeats.settleStart),
      lineStart: tail,
      lineEnd: head,
      lineThickness: thick,
      cutEnd: ms >= LapDrawBeats.drawEnd ? l.size.width : head,
      cutThickness: l.markCut * cutP,
      wordOpacity: word,
      wordDy: 8 * (1 - word),
    );
  }
  // 0.6 s: the R is already cut; only its own line draws.
  final p = MotionCurves.emphasized.transform(
    _seg(ms, LapDrawBeats.fadeInEnd, LapDrawBeats.shortDrawEnd),
  );
  final exit = MotionCurves.exit.transform(
    _seg(ms, LapDrawBeats.shortDrawEnd, LapDrawBeats.shortEnd),
  );
  return LapDrawFrame(
    opacity: fadeIn * (1 - exit),
    scale: _lerp(1, 0.96, exit),
    markScale: 1,
    lineStart: l.legEntry,
    lineEnd: _lerp(l.legEntry, l.tailEnd, p),
    lineThickness: l.markLine,
    cutEnd: l.size.width,
    cutThickness: l.markCut,
    wordOpacity: 0,
    wordDy: 0,
  );
}

/// When the full version's head first reaches the R's left edge, ms.
double? _headReachesMs(LapDrawLayout l) {
  for (var ms = LapDrawBeats.fadeInEnd; ms <= LapDrawBeats.drawEnd; ms++) {
    final p = MotionCurves.emphasized.transform(
      _seg(ms.toDouble(), LapDrawBeats.fadeInEnd, LapDrawBeats.drawEnd),
    );
    if (p * l.size.width >= l.rLeft) return ms.toDouble();
  }
  return null;
}

/// Scale then translate, as a column-major 4x4 for [Path.transform].
Float64List _affine(double s, Offset o) => Float64List.fromList([
  s, 0, 0, 0, //
  0, s, 0, 0, //
  0, 0, 1, 0, //
  o.dx, o.dy, 0, 1,
]);

class LapDrawPainter extends CustomPainter {
  LapDrawPainter({
    required this.frame,
    required this.layout,
    required this.bone,
    required this.arc,
  });

  final LapDrawFrame frame;
  final LapDrawLayout layout;
  final Color bone;
  final Color arc;

  static final Path _r = lapLineR();
  static final Path _word = lapLineWordmark();
  static final Path _dash = lapLineWordDash();

  @override
  void paint(Canvas canvas, Size size) {
    final f = frame;
    if (f.opacity <= 0) return;
    final l = layout;
    final alpha = f.opacity.clamp(0.0, 1.0);
    canvas.save();
    final c = l.rCentre;
    canvas
      ..translate(c.dx, c.dy)
      ..scale(f.scale)
      ..translate(-c.dx, -c.dy);

    // The R and its line, settling about the R's centre.
    canvas
      ..save()
      ..translate(c.dx, c.dy)
      ..scale(f.markScale)
      ..translate(-c.dx, -c.dy);
    var r = _r.transform(_affine(l.s, l.origin));
    if (f.cutThickness > 0 && f.cutEnd > 0) {
      final gap = Rect.fromLTRB(
        0,
        l.cutY - f.cutThickness / 2,
        f.cutEnd,
        l.cutY + f.cutThickness / 2,
      );
      r = Path.combine(PathOperation.difference, r, Path()..addRect(gap));
    }
    canvas.drawPath(r, Paint()..color = bone.withValues(alpha: alpha));
    final len = f.lineEnd - f.lineStart;
    if (len > 0.5) {
      final t = f.lineThickness;
      // Square where it enters, round leading end (brand geometry).
      final line = Path()
        ..addRRect(
          RRect.fromLTRBAndCorners(
            f.lineStart,
            l.cutY - t / 2,
            f.lineEnd,
            l.cutY + t / 2,
            topRight: Radius.circular(math.min(t / 2, len)),
            bottomRight: Radius.circular(math.min(t / 2, len)),
          ),
        );
      canvas.drawPath(line, Paint()..color = arc.withValues(alpha: alpha));
    }
    canvas.restore();

    if (f.wordOpacity > 0) {
      final m = _affine(l.ws, l.wordOrigin.translate(0, f.wordDy));
      final a = alpha * f.wordOpacity;
      canvas
        ..drawPath(
          _word.transform(m),
          Paint()..color = bone.withValues(alpha: a),
        )
        ..drawPath(
          _dash.transform(m),
          Paint()..color = arc.withValues(alpha: a),
        );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(LapDrawPainter old) =>
      old.frame != frame || old.layout.size != layout.size;
}

/// Plays one intro over the app and calls [onDone] when it has faded out.
/// Tap anywhere skips to a 160 ms exit. Reduced motion: the final frame for
/// 300 ms, then a cut. Silent: no haptic, no sound.
class LapDrawIntro extends StatefulWidget {
  const LapDrawIntro({
    super.key,
    required this.kind,
    required this.onDone,
    this.reducedMotion = false,
  });

  final IntroKind kind;
  final VoidCallback onDone;
  final bool reducedMotion;

  @override
  State<LapDrawIntro> createState() => _LapDrawIntroState();
}

class _LapDrawIntroState extends State<LapDrawIntro>
    with TickerProviderStateMixin {
  late final AnimationController _play;
  AnimationController? _skip;
  double? _skippedAt;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    final total = widget.reducedMotion
        ? LapDrawBeats.reducedHoldMs
        : LapDrawBeats.total(widget.kind);
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
    _skippedAt = LapDrawBeats.finalFrame(widget.kind).toDouble();
    _skip =
        AnimationController(
            vsync: this,
            duration: const Duration(milliseconds: LapDrawBeats.skipFadeMs),
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

  LapDrawFrame _frame(LapDrawLayout l) {
    if (widget.reducedMotion) {
      // Static final frame, then a cut (no fade).
      return lapDrawFrameAt(
        widget.kind,
        LapDrawBeats.finalFrame(widget.kind).toDouble(),
        l,
      );
    }
    final skip = _skip;
    if (skip != null) {
      final f = lapDrawFrameAt(widget.kind, _skippedAt!, l);
      final p = MotionCurves.exit.transform(skip.value);
      return LapDrawFrame(
        opacity: f.opacity * (1 - p),
        scale: 1 - 0.04 * p,
        markScale: f.markScale,
        lineStart: f.lineStart,
        lineEnd: f.lineEnd,
        lineThickness: f.lineThickness,
        cutEnd: f.cutEnd,
        cutThickness: f.cutThickness,
        wordOpacity: f.wordOpacity,
        wordDy: f.wordDy,
      );
    }
    return lapDrawFrameAt(
      widget.kind,
      _play.value * LapDrawBeats.total(widget.kind),
      l,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return LayoutBuilder(
      builder: (context, box) {
        final l = LapDrawLayout(box.biggest);
        final f = _frame(l);
        // The black ground fades with the composition, revealing Home.
        final ground = widget.reducedMotion || _skip != null
            ? f.opacity
            : _groundOpacity();
        return GestureDetector(
          key: const ValueKey('lap-draw-intro'),
          behavior: HitTestBehavior.opaque,
          onTap: _onTap,
          child: Semantics(
            label: 'Run Supreme',
            child: ColoredBox(
              color: t.bgBase.withValues(alpha: ground.clamp(0.0, 1.0)),
              child: CustomPaint(
                size: box.biggest,
                painter: LapDrawPainter(
                  frame: f,
                  layout: l,
                  bone: t.inkPrimary,
                  arc: t.accentArc,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// The ground stays solid until the exit beat, then fades with it (the
  /// first 150 ms are the system splash's black, so no fade-in).
  double _groundOpacity() {
    final ms = _play.value * LapDrawBeats.total(widget.kind);
    final start = widget.kind == IntroKind.full
        ? LapDrawBeats.fullExitStart
        : LapDrawBeats.shortDrawEnd;
    final p = MotionCurves.exit.transform(
      _seg(ms, start, LapDrawBeats.total(widget.kind)),
    );
    return 1 - p;
  }
}
