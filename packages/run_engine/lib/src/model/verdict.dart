import 'dart:convert';

import '../run_mode.dart';
import 'run_file.dart';
import 'sidecar.dart';

/// Which comparison produced the verdict (plan §5 staged verdict).
enum VerdictStage {
  /// First 4x4: within-session baseline.
  baseline,

  /// Second 4x4: rep-by-rep vs the first, floor x sqrt(2).
  vsLast,

  /// Third and later: vs the median of the last 6 prior 4x4s.
  vsMedian,

  /// No comparison possible (interrupted, noisy, indoor, laps inconsistent).
  none,
}

/// The one-word headline, pinned to the design brief's verdict copy set.
enum VerdictHeadline {
  faster('FASTER'),
  holding('HOLDING'),
  slower('SLOWER'),
  noRealChange('NO REAL CHANGE'),
  baselineSet('BASELINE SET'),
  noVerdict('NO VERDICT'),
  indoorRun('INDOOR RUN');

  const VerdictHeadline(this.text);

  /// ALL CAPS, the only place caps are allowed besides the LAP button.
  final String text;
}

/// A verdict is point-in-time and frozen (plan §5): everything needed to
/// reproduce it on a rebuild travels with it in the sidecar (§17 R3).
class Verdict {
  const Verdict({
    required this.stage,
    required this.headline,
    required this.subline,
    this.hrLine,
    this.currentSecPerKm,
    this.baselineSecPerKm,
    this.deltaSecPerKm,
    this.rank,
    this.setSize,
    this.setIds = const [],
    required this.floorSecPerKm,
    required this.bandSecPerKm,
    required this.engineVersion,
    required this.computedAt,
    this.bestIn365Days = false,
    this.trendSecPerKmPerWeek,
    this.inputsKey = '',
  });

  final VerdictStage stage;
  final VerdictHeadline headline;

  /// One or two sentences, max 9 words per line, no em-dashes.
  final String subline;

  /// Third line, only when HR was present.
  final String? hrLine;

  /// Avg work pace of this run (s/km), null when no pace verdict.
  final double? currentSecPerKm;

  /// The comparison value: run 1's pace (run 2) or the median (run 3+).
  final double? baselineSecPerKm;

  /// baseline − current: positive = faster.
  final double? deltaSecPerKm;

  /// Run 3+: how many of the comparison set this run beat.
  final int? rank;
  final int? setSize;
  final List<String> setIds;

  /// The noise floor applied (10, or 14.14 for run 2) and the rep band.
  final double floorSecPerKm;
  final double bandSecPerKm;
  final int engineVersion;
  final DateTime computedAt;

  /// Run 3+: more than 1% better than every eligible run in the last 365 days.
  final bool bestIn365Days;

  /// Theil–Sen slope over 12 weeks once >= 5 runs across >= 4 weeks; negative
  /// means getting faster.
  final double? trendSecPerKmPerWeek;

  /// Fingerprint of the sidecar inputs (lap edits + override) the verdict was
  /// computed from. A frozen verdict whose key no longer matches the sidecar
  /// (e.g. edits merged in from a DB restore) is recomputed, never trusted.
  final String inputsKey;

  static String inputsKeyFor(List<LapEdit> edits, RunMode? override) =>
      jsonEncode({
        'edits': edits.map((e) => e.toJson()).toList(),
        'override': override?.name,
      });

  /// Same headline and wording (what a runner reads), whatever the numbers
  /// or engine version behind them.
  bool sameText(Verdict other) =>
      headline == other.headline &&
      subline == other.subline &&
      hrLine == other.hrLine;

  bool get hasPaceVerdict =>
      stage != VerdictStage.none && headline != VerdictHeadline.indoorRun;

  Map<String, Object?> toJson() => {
    'stage': stage.name,
    'headline_key': headline.name,
    'headline': headline.text,
    'subline': subline,
    'hr_line': hrLine,
    'current_s_per_km': currentSecPerKm,
    'baseline_s_per_km': baselineSecPerKm,
    'delta_s_per_km': deltaSecPerKm,
    'rank': rank,
    'set_size': setSize,
    'set_ids': setIds,
    'floor_s_per_km': floorSecPerKm,
    'band_s_per_km': bandSecPerKm,
    'engine_version': engineVersion,
    'computed_at': computedAt.toUtc().toIso8601String(),
    'best_365d': bestIn365Days,
    'trend_s_per_km_per_week': trendSecPerKmPerWeek,
    'inputs_key': inputsKey,
  };

  factory Verdict.fromJson(Map<String, Object?> json) {
    final stageName = readStringField(json, 'stage');
    final stage = VerdictStage.values.cast<VerdictStage?>().firstWhere(
      (s) => s!.name == stageName,
      orElse: () => null,
    );
    if (stage == null) throw RunFileFormatException('verdict.stage unknown');
    final headlineKey = readStringField(json, 'headline_key');
    final headline = VerdictHeadline.values.cast<VerdictHeadline?>().firstWhere(
      (h) => h!.name == headlineKey,
      orElse: () => null,
    );
    if (headline == null) {
      throw RunFileFormatException('verdict.headline_key unknown');
    }
    double? optDouble(String key) {
      final v = json[key];
      if (v == null) return null;
      if (v is! num) throw RunFileFormatException('verdict.$key must be num');
      return v.toDouble();
    }

    int? optInt(String key) {
      final v = json[key];
      if (v == null) return null;
      if (v is! int) throw RunFileFormatException('verdict.$key must be int');
      return v;
    }

    final setIds = json['set_ids'];
    if (setIds is! List || setIds.any((e) => e is! String)) {
      throw RunFileFormatException('verdict.set_ids must be a string list');
    }
    final hrLine = json['hr_line'];
    if (hrLine != null && hrLine is! String) {
      throw RunFileFormatException('verdict.hr_line must be string or null');
    }
    return Verdict(
      stage: stage,
      headline: headline,
      subline: readStringField(json, 'subline'),
      hrLine: hrLine as String?,
      currentSecPerKm: optDouble('current_s_per_km'),
      baselineSecPerKm: optDouble('baseline_s_per_km'),
      deltaSecPerKm: optDouble('delta_s_per_km'),
      rank: optInt('rank'),
      setSize: optInt('set_size'),
      setIds: setIds.cast<String>(),
      floorSecPerKm: readDoubleField(json, 'floor_s_per_km'),
      bandSecPerKm: readDoubleField(json, 'band_s_per_km'),
      engineVersion: readIntField(json, 'engine_version'),
      computedAt: readDateTimeField(json, 'computed_at'),
      bestIn365Days: json['best_365d'] == true,
      trendSecPerKmPerWeek: optDouble('trend_s_per_km_per_week'),
      inputsKey: (json['inputs_key'] as String?) ?? '',
    );
  }
}
