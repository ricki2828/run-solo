import 'package:flutter/material.dart';

/// Night Session colour tokens (design brief §2.2, dark-first).
/// Cyan is earned: it appears only on FASTER / PB / plan-week done.
abstract final class NightSession {
  // Backgrounds
  static const Color bgBase = Color(0xFF0A0B0D);
  static const Color bgRaised = Color(0xFF141619);
  static const Color bgSunken = Color(0xFF050506);
  static const Color lineHair = Color(0x14FFFFFF);

  // Ink
  static const Color inkPrimary = Color(0xFFEDEAE3); // Bone
  static const Color inkSecondary = Color(0xFFA5A9B1);
  static const Color inkMuted = Color(0xFF5F646D); // Concrete

  // Accent
  static const Color accentArc = Color(0xFF19E6FF);
  static const Color accentArcInk = Color(0xFF06252B);

  // Semantic
  static const Color semFaster = accentArc;
  static const Color semSlower = Color(0xFFFF5C3A); // Vermillion
  static const Color semHolding = inkPrimary;
  static const Color semNoise = Color(0xFF8A8F98);
  static const Color semWarn = Color(0xFFFFB020);
  static const Color semDanger = Color(0xFFFF3B3B);
  static const Color hrZone = Color(0xFFB48CFF);
}

/// Light variant (design brief §2.2). Not the default; kept so the tokens stay paired.
abstract final class NightSessionLight {
  static const Color bgBase = Color(0xFFF4F2EE);
  static const Color bgRaised = Color(0xFFFFFFFF);
  static const Color bgSunken = Color(0xFFE9E6E0);
  static const Color lineHair = Color(0x1A000000);
  static const Color inkPrimary = Color(0xFF0F1114);
  static const Color inkSecondary = Color(0xFF4B5058);
  static const Color inkMuted = Color(0xFF8A8F98);
  static const Color accentArc = Color(0xFF0098B2);
  static const Color accentArcInk = Color(0xFFFFFFFF);
  static const Color semFaster = accentArc;
  static const Color semSlower = Color(0xFFC93A1C);
  static const Color semHolding = inkPrimary;
  static const Color semNoise = Color(0xFF6B7079);
  static const Color semWarn = Color(0xFF8A5A00);
  static const Color semDanger = Color(0xFFB00020);
  static const Color hrZone = Color(0xFF6B3FD6);
}

/// Spacing scale in dp (design brief §5).
abstract final class Space {
  static const double x4 = 4;
  static const double x8 = 8;
  static const double x12 = 12;
  static const double x16 = 16;
  static const double x24 = 24;
  static const double x32 = 32;
  static const double x48 = 48;
  static const double x64 = 64;
  static const double screenGutter = 20;
  static const double recordGutter = 16;
  static const double cardPadding = 16;
}

abstract final class Radii {
  static const double chip = 8;
  static const double card = 16;
  static const double sheet = 24;
  static const double button = 12;
  static const double lap = 20;
  static const double pill = 999;
}

/// Semantic colours, radii and spacing reachable via `Theme.of(context).extension<RunSoloTokens>()`.
@immutable
class RunSoloTokens extends ThemeExtension<RunSoloTokens> {
  const RunSoloTokens({
    required this.bgBase,
    required this.bgRaised,
    required this.bgSunken,
    required this.lineHair,
    required this.inkPrimary,
    required this.inkSecondary,
    required this.inkMuted,
    required this.accentArc,
    required this.accentArcInk,
    required this.semFaster,
    required this.semSlower,
    required this.semHolding,
    required this.semNoise,
    required this.semWarn,
    required this.semDanger,
    required this.hrZone,
  });

  static const RunSoloTokens dark = RunSoloTokens(
    bgBase: NightSession.bgBase,
    bgRaised: NightSession.bgRaised,
    bgSunken: NightSession.bgSunken,
    lineHair: NightSession.lineHair,
    inkPrimary: NightSession.inkPrimary,
    inkSecondary: NightSession.inkSecondary,
    inkMuted: NightSession.inkMuted,
    accentArc: NightSession.accentArc,
    accentArcInk: NightSession.accentArcInk,
    semFaster: NightSession.semFaster,
    semSlower: NightSession.semSlower,
    semHolding: NightSession.semHolding,
    semNoise: NightSession.semNoise,
    semWarn: NightSession.semWarn,
    semDanger: NightSession.semDanger,
    hrZone: NightSession.hrZone,
  );

  static const RunSoloTokens light = RunSoloTokens(
    bgBase: NightSessionLight.bgBase,
    bgRaised: NightSessionLight.bgRaised,
    bgSunken: NightSessionLight.bgSunken,
    lineHair: NightSessionLight.lineHair,
    inkPrimary: NightSessionLight.inkPrimary,
    inkSecondary: NightSessionLight.inkSecondary,
    inkMuted: NightSessionLight.inkMuted,
    accentArc: NightSessionLight.accentArc,
    accentArcInk: NightSessionLight.accentArcInk,
    semFaster: NightSessionLight.semFaster,
    semSlower: NightSessionLight.semSlower,
    semHolding: NightSessionLight.semHolding,
    semNoise: NightSessionLight.semNoise,
    semWarn: NightSessionLight.semWarn,
    semDanger: NightSessionLight.semDanger,
    hrZone: NightSessionLight.hrZone,
  );

  final Color bgBase;
  final Color bgRaised;
  final Color bgSunken;
  final Color lineHair;
  final Color inkPrimary;
  final Color inkSecondary;
  final Color inkMuted;
  final Color accentArc;
  final Color accentArcInk;
  final Color semFaster;
  final Color semSlower;
  final Color semHolding;
  final Color semNoise;
  final Color semWarn;
  final Color semDanger;
  final Color hrZone;

  @override
  RunSoloTokens copyWith({
    Color? bgBase,
    Color? bgRaised,
    Color? bgSunken,
    Color? lineHair,
    Color? inkPrimary,
    Color? inkSecondary,
    Color? inkMuted,
    Color? accentArc,
    Color? accentArcInk,
    Color? semFaster,
    Color? semSlower,
    Color? semHolding,
    Color? semNoise,
    Color? semWarn,
    Color? semDanger,
    Color? hrZone,
  }) {
    return RunSoloTokens(
      bgBase: bgBase ?? this.bgBase,
      bgRaised: bgRaised ?? this.bgRaised,
      bgSunken: bgSunken ?? this.bgSunken,
      lineHair: lineHair ?? this.lineHair,
      inkPrimary: inkPrimary ?? this.inkPrimary,
      inkSecondary: inkSecondary ?? this.inkSecondary,
      inkMuted: inkMuted ?? this.inkMuted,
      accentArc: accentArc ?? this.accentArc,
      accentArcInk: accentArcInk ?? this.accentArcInk,
      semFaster: semFaster ?? this.semFaster,
      semSlower: semSlower ?? this.semSlower,
      semHolding: semHolding ?? this.semHolding,
      semNoise: semNoise ?? this.semNoise,
      semWarn: semWarn ?? this.semWarn,
      semDanger: semDanger ?? this.semDanger,
      hrZone: hrZone ?? this.hrZone,
    );
  }

  @override
  RunSoloTokens lerp(ThemeExtension<RunSoloTokens>? other, double t) {
    if (other is! RunSoloTokens) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return RunSoloTokens(
      bgBase: l(bgBase, other.bgBase),
      bgRaised: l(bgRaised, other.bgRaised),
      bgSunken: l(bgSunken, other.bgSunken),
      lineHair: l(lineHair, other.lineHair),
      inkPrimary: l(inkPrimary, other.inkPrimary),
      inkSecondary: l(inkSecondary, other.inkSecondary),
      inkMuted: l(inkMuted, other.inkMuted),
      accentArc: l(accentArc, other.accentArc),
      accentArcInk: l(accentArcInk, other.accentArcInk),
      semFaster: l(semFaster, other.semFaster),
      semSlower: l(semSlower, other.semSlower),
      semHolding: l(semHolding, other.semHolding),
      semNoise: l(semNoise, other.semNoise),
      semWarn: l(semWarn, other.semWarn),
      semDanger: l(semDanger, other.semDanger),
      hrZone: l(hrZone, other.hrZone),
    );
  }
}
