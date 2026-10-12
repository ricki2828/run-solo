import 'package:flutter/material.dart';

/// Direction B ("Cohort") look, 12-Oct-2026. Fixed in both themes: the pack
/// is the one big colour block on an otherwise light page.
///
/// Violet is deep enough for white text at 6.1:1 (the brief's lighter violet
/// only reaches 4.2:1). Lane blocks reuse the lane colours from
/// `lanes.dart`; nothing here is a lane colour.
abstract final class PackLook {
  /// The pack hero ground.
  static const Color violet = Color(0xFF6D3FE0);

  /// Text on [violet] (6.1:1).
  static const Color onViolet = Color(0xFFFFFFFF);

  /// Secondary text on [violet]; still above 4.5:1.
  static const Color onVioletSoft = Color(0xFFEDE6FF);

  /// A chip or panel sitting on [violet].
  static const Color violetPanel = Color(0x33FFFFFF);

  /// The crowd bars in the pack histogram.
  static const Color crowdBar = Color(0x80FFFFFF);

  /// The "you" bar and its tag: near-black so it is the loudest thing.
  static const Color youBar = Color(0xFF121417);
  static const Color onYouBar = Color(0xFFFFFFFF);

  /// How strongly a lane colour tints a whole block on the light page.
  static const double laneTint = 0.16;
}
