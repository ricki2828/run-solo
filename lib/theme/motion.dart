import 'package:flutter/animation.dart';

/// Motion tokens (design brief §4). Motion confirms, it never decorates;
/// nothing loops while recording.
abstract final class MotionDurations {
  static const Duration instant = Duration(milliseconds: 80);
  static const Duration quick = Duration(milliseconds: 160);
  static const Duration base = Duration(milliseconds: 240);
  static const Duration slow = Duration(milliseconds: 400);
  static const Duration hero = Duration(milliseconds: 1400);
}

abstract final class MotionCurves {
  static const Curve standard = Cubic(0.2, 0, 0, 1);
  static const Curve emphasized = Cubic(0.05, 0.7, 0.1, 1);
  static const Curve exit = Cubic(0.3, 0, 1, 1);
}

/// Spring parameters (mass, stiffness, damping) for direct-manipulation moments.
abstract final class MotionSprings {
  static const ({double mass, double stiffness, double damping}) tap = (
    mass: 1,
    stiffness: 500,
    damping: 30,
  );
  static const ({double mass, double stiffness, double damping}) sheet = (
    mass: 1,
    stiffness: 300,
    damping: 26,
  );
}
