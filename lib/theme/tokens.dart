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
  static const Color semFaster = semImproving; // faster is mint everywhere
  static const Color semSlower = Color(0xFFFF5C3A); // Vermillion
  static const Color semImproving = Color(0xFF2EE6A8); // mint
  static const Color semHolding = inkPrimary;
  static const Color semNoise = Color(0xFF8A8F98);
  static const Color semWarn = Color(0xFFFFB020);
  static const Color semDanger = Color(0xFFFF3B3B);
  static const Color hrZone = pulseRose; // heart icons: strap rose, not lilac
  static const Color pulseRose = Color(0xFFFF5C8A); // labelled strap state

  // Fixed overlays and textures (no Aurora role; named so lib/ has no literals)
  static const Color structureOpen = Color(0xFF2E3238); // open interval glyph
  static const Color overlayInk = Color(0xB3EDEAE3); // Bone 70 %
  static const Color overlayGround = Color(0xD9000000); // black 85 %
  static const Color overlayBorder = Color(0x33EDEAE3); // Bone 20 %
  static const Color grain = Color(0x05FFFFFF); // verdict background grain
}

/// Aurora run-type identities. These colours identify *which* run the runner
/// picked, never whether a result was good or an HR zone was desirable.
/// Keep selected text and its check together so colour is not the only cue.
abstract final class AuroraRunType {
  static const Color free = Color(0xFF7CDBFF); // ice
  static const Color laps = Color(0xFF19E6FF); // Lap Line cyan
  static const Color goal = Color(0xFFB48CFF); // violet
  static const Color intervals = Color(0xFFFF6EC7); // magenta
  static const Color tests = Color(0xFF8CFF5C); // lime

  /// Trail: moss, an earthy amber-green (hue 64 deg, 62 % saturation). It sits
  /// between Tests lime (103 deg, fully saturated) and the Z3/warning amber
  /// (40 deg), 39 deg and 24 deg away and visibly duller than both, so it
  /// reads as dirt and lichen where the others glow. It is nowhere near the
  /// improving mint (159 deg). 9.2:1 on the raised card ground. Always shown
  /// with the word "Trail", like every run-type colour.
  static const Color trail = Color(0xFFB8C04C);
}

/// Weekly story ground: a deep indigo that carries no lane, run-type, HR zone
/// or semantic meaning (a test holds it at least 60 RGB from all of them, in
/// both themes). White ink on it is 7:1.
abstract final class AuroraStory {
  static const Color fill = Color(0xFF5A2DE0);
}

/// Route-line gradient classes (10-Oct trail run). Kept clear of the zone
/// ramp, the semantic mint / vermillion / cyan and the run-type identities
/// (a test measures the distance), so a colour on the map never doubles as
/// an HR zone or a verdict. Bone-white flat, lemon up, peach steep (also drawn wider), grey-teal
/// down. The saturated warm and cool space is taken by the zones and
/// semantics, so these are pale tints, at least 90 away from every one.
abstract final class AuroraGradient {
  static const Color flat = Color(0xFFE4E2DC);
  static const Color up = Color(0xFFFFFF66);
  static const Color steep = Color(0xFFFFB78F);
  static const Color down = Color(0xFF85A5AD);
}

/// The retraced-stretch band on the map: a Bone halo inside a dark rim. The
/// topo map is a dark map in both themes, so both themes use the same pair;
/// they are tokens so a test measures them against the map and the gradient
/// colours in each theme.
abstract final class AuroraRetrace {
  static const Color halo = Color(0xFFEDEAE3); // Bone
  static const Color rim = Color(0xFF0A0B0D);
}

/// Light everyday palette (brand build, 7-Oct-2026). Ground #FBFBF9, white
/// raised surface with a hairline, ink #121417. Contrast on the ground:
/// ink 17.8, secondary 7.9, quiet 4.6, mint 4.6, vermillion 4.8 (all >= 4.5).
abstract final class NightSessionLight {
  static const Color bgBase = Color(0xFFFBFBF9);
  static const Color bgRaised = Color(0xFFFFFFFF);
  static const Color bgSunken = Color(0xFFF1F2EE);
  static const Color lineHair = Color(0xFFE3E5E0);
  static const Color inkPrimary = Color(0xFF121417);
  static const Color inkSecondary = Color(0xFF4A5058);
  // Brief asked for #6E7781 (4.39:1 on the ground); nudged to clear 4.5.
  static const Color inkMuted = Color(0xFF6C747E);
  static const Color accentArc = Color(0xFF007E93);
  static const Color accentArcInk = Color(0xFFFFFFFF);
  static const Color semFaster = semImproving; // faster is mint everywhere
  // Brief example #1D8A5A is 4.19:1; this is the same hue at 4.6:1.
  static const Color semImproving = Color(0xFF1C8356); // mint, light ground
  static const Color semSlower = Color(0xFFC8401E); // vermillion
  static const Color semHolding = inkPrimary;
  static const Color semNoise = Color(0xFF6B7079);
  static const Color semWarn = Color(0xFF8A5A00);
  static const Color semDanger = Color(0xFFB00020);
  static const Color hrZone = Color(
    0xFFC2255A,
  ); // rose, darkened for light ground
  static const Color structureOpen = Color(0xFFB4B8B1); // open interval glyph
  static const Color grain = Color(0x08000000); // verdict background grain
}

/// Run-type identities on the light ground: the same hues as [AuroraRunType],
/// darkened until each is >= 3:1 (large text, graphics) on #FBFBF9.
abstract final class AuroraRunTypeLight {
  static const Color free = Color(0xFF0095CE);
  static const Color laps = Color(0xFF009AAD);
  static const Color goal = Color(0xFFA270FF);
  static const Color intervals = Color(0xFFFF31AF);
  static const Color tests = Color(0xFF2FA100);
  static const Color trail = Color(0xFF8B9133);
}

/// Home card topo snapshots (the printed-map style): the route's casing on
/// the light card and the grey the lane is mixed into for contours and trails.
abstract final class TopoCard {
  static const Color casingLight = Color(0xFFFFFFFF);
  static const Color contourGreyLight = Color(0xFFA2A49C);
  static const Color contourGreyDark = Color(0xFF6A7075);
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
    required this.semImproving,
    required this.semSlower,
    required this.semHolding,
    required this.semNoise,
    required this.semWarn,
    required this.semDanger,
    required this.hrZone,
    required this.typeFree,
    required this.typeLaps,
    required this.typeGoal,
    required this.typeIntervals,
    required this.typeTests,
    required this.typeTrail,
    required this.structureOpen,
    required this.grain,
    required this.retraceHalo,
    required this.retraceRim,
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
    semImproving: NightSession.semImproving,
    semSlower: NightSession.semSlower,
    semHolding: NightSession.semHolding,
    semNoise: NightSession.semNoise,
    semWarn: NightSession.semWarn,
    semDanger: NightSession.semDanger,
    hrZone: NightSession.hrZone,
    typeFree: AuroraRunType.free,
    typeLaps: AuroraRunType.laps,
    typeGoal: AuroraRunType.goal,
    typeIntervals: AuroraRunType.intervals,
    typeTests: AuroraRunType.tests,
    typeTrail: AuroraRunType.trail,
    structureOpen: NightSession.structureOpen,
    grain: NightSession.grain,
    retraceHalo: AuroraRetrace.halo,
    retraceRim: AuroraRetrace.rim,
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
    semImproving: NightSessionLight.semImproving,
    semSlower: NightSessionLight.semSlower,
    semHolding: NightSessionLight.semHolding,
    semNoise: NightSessionLight.semNoise,
    semWarn: NightSessionLight.semWarn,
    semDanger: NightSessionLight.semDanger,
    hrZone: NightSessionLight.hrZone,
    typeFree: AuroraRunTypeLight.free,
    typeLaps: AuroraRunTypeLight.laps,
    typeGoal: AuroraRunTypeLight.goal,
    typeIntervals: AuroraRunTypeLight.intervals,
    typeTests: AuroraRunTypeLight.tests,
    typeTrail: AuroraRunTypeLight.trail,
    structureOpen: NightSessionLight.structureOpen,
    grain: NightSessionLight.grain,
    retraceHalo: AuroraRetrace.halo,
    retraceRim: AuroraRetrace.rim,
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

  /// Mint: a labelled improvement in a score or comparison.
  final Color semImproving;
  final Color semSlower;
  final Color semHolding;
  final Color semNoise;
  final Color semWarn;
  final Color semDanger;
  final Color hrZone;

  /// Run-type identities (which run, never how good it was).
  final Color typeFree;
  final Color typeLaps;
  final Color typeGoal;
  final Color typeIntervals;
  final Color typeTests;
  final Color typeTrail;

  /// Open warm-up / cool-down glyph bars and the verdict grain.
  final Color structureOpen;
  final Color grain;

  /// Retraced stretch on the (always dark) topo map.
  final Color retraceHalo;
  final Color retraceRim;

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
    Color? semImproving,
    Color? semSlower,
    Color? semHolding,
    Color? semNoise,
    Color? semWarn,
    Color? semDanger,
    Color? hrZone,
    Color? typeFree,
    Color? typeLaps,
    Color? typeGoal,
    Color? typeIntervals,
    Color? typeTests,
    Color? typeTrail,
    Color? structureOpen,
    Color? grain,
    Color? retraceHalo,
    Color? retraceRim,
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
      semImproving: semImproving ?? this.semImproving,
      semSlower: semSlower ?? this.semSlower,
      semHolding: semHolding ?? this.semHolding,
      semNoise: semNoise ?? this.semNoise,
      semWarn: semWarn ?? this.semWarn,
      semDanger: semDanger ?? this.semDanger,
      hrZone: hrZone ?? this.hrZone,
      typeFree: typeFree ?? this.typeFree,
      typeLaps: typeLaps ?? this.typeLaps,
      typeGoal: typeGoal ?? this.typeGoal,
      typeIntervals: typeIntervals ?? this.typeIntervals,
      typeTests: typeTests ?? this.typeTests,
      typeTrail: typeTrail ?? this.typeTrail,
      structureOpen: structureOpen ?? this.structureOpen,
      grain: grain ?? this.grain,
      retraceHalo: retraceHalo ?? this.retraceHalo,
      retraceRim: retraceRim ?? this.retraceRim,
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
      semImproving: l(semImproving, other.semImproving),
      semSlower: l(semSlower, other.semSlower),
      semHolding: l(semHolding, other.semHolding),
      semNoise: l(semNoise, other.semNoise),
      semWarn: l(semWarn, other.semWarn),
      semDanger: l(semDanger, other.semDanger),
      hrZone: l(hrZone, other.hrZone),
      typeFree: l(typeFree, other.typeFree),
      typeLaps: l(typeLaps, other.typeLaps),
      typeGoal: l(typeGoal, other.typeGoal),
      typeIntervals: l(typeIntervals, other.typeIntervals),
      typeTests: l(typeTests, other.typeTests),
      typeTrail: l(typeTrail, other.typeTrail),
      structureOpen: l(structureOpen, other.structureOpen),
      grain: l(grain, other.grain),
      retraceHalo: l(retraceHalo, other.retraceHalo),
      retraceRim: l(retraceRim, other.retraceRim),
    );
  }
}
