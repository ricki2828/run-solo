import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../state/sessions.dart';
import '../theme/theme.dart';

/// A session's shape in one line (design brief A8): bar width = step time
/// (distance steps estimated), height = effort. Rep = Bone at full height,
/// recovery = Concrete at 34 %, open warm-up / cool-down = `#2E3238` at 30 %
/// and 10 minutes wide. Gap 0.8, corner 0.6. Never Arc.
class StructureGlyph extends StatelessWidget {
  const StructureGlyph({super.key, required this.spec, this.height = 14});

  final engine.SessionSpec spec;
  final double height;

  static const Color openColour = Color(0xFF2E3238);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return ExcludeSemantics(
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: _GlyphPainter(
            bars: Glyph.durations(spec),
            rep: t.inkPrimary,
            recovery: t.inkMuted,
            open: openColour,
          ),
        ),
      ),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter({
    required this.bars,
    required this.rep,
    required this.recovery,
    required this.open,
  });

  final List<(GlyphBar, double)> bars;
  final Color rep;
  final Color recovery;
  final Color open;

  static const double gap = 0.8;

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty || size.width <= 0) return;
    final total = bars.fold<double>(0, (a, b) => a + b.$2);
    final avail = size.width - gap * (bars.length - 1);
    if (total <= 0 || avail <= 0) return;
    var x = 0.0;
    for (final (kind, secs) in bars) {
      final w = (avail * secs / total).clamp(0.6, double.infinity);
      final (hFrac, colour) = switch (kind) {
        GlyphBar.rep => (1.0, rep),
        GlyphBar.recovery => (0.34, recovery),
        GlyphBar.open => (0.30, open),
      };
      final h = size.height * hFrac;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, size.height - h, w, h),
          const Radius.circular(0.6),
        ),
        Paint()..color = colour,
      );
      x += w + gap;
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.bars.length != bars.length ||
      old.rep != rep ||
      !_same(old.bars, bars);

  static bool _same(List<(GlyphBar, double)> a, List<(GlyphBar, double)> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
