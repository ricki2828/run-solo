import 'package:flutter/material.dart';

/// ▲ ▼ ▬ drawn on a canvas. The bundled fonts (Barlow Condensed, Archivo)
/// carry no geometric-shape glyphs, so a text arrow renders as tofu on
/// devices without a fallback font and in every golden. Every verdict still
/// carries the word; this is the arrow beside it (design brief §2.2
/// colour-blind rule).
enum DeltaDirection { up, down, flat }

class DeltaGlyph extends StatelessWidget {
  const DeltaGlyph({
    super.key,
    required this.direction,
    required this.color,
    this.size = 12,
  });

  final DeltaDirection direction;
  final Color color;
  final double size;

  /// Live minus last (or current minus baseline), s/km: negative = faster.
  static DeltaDirection forDelta(double deltaSecPerKm, {double dead = 1}) =>
      deltaSecPerKm < -dead
      ? DeltaDirection.up
      : deltaSecPerKm > dead
      ? DeltaDirection.down
      : DeltaDirection.flat;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: CustomPaint(
      size: Size(size, size),
      painter: _DeltaPainter(direction, color),
    ),
  );
}

class _DeltaPainter extends CustomPainter {
  _DeltaPainter(this.direction, this.color);
  final DeltaDirection direction;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color;
    final w = size.width;
    final h = size.height;
    switch (direction) {
      case DeltaDirection.up:
        canvas.drawPath(
          Path()
            ..moveTo(w / 2, h * 0.15)
            ..lineTo(w, h * 0.85)
            ..lineTo(0, h * 0.85)
            ..close(),
          p,
        );
      case DeltaDirection.down:
        canvas.drawPath(
          Path()
            ..moveTo(0, h * 0.15)
            ..lineTo(w, h * 0.15)
            ..lineTo(w / 2, h * 0.85)
            ..close(),
          p,
        );
      case DeltaDirection.flat:
        canvas.drawRect(Rect.fromLTWH(0, h * 0.4, w, h * 0.2), p);
    }
  }

  @override
  bool shouldRepaint(_DeltaPainter old) =>
      old.direction != direction || old.color != color;
}
