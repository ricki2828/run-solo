import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../platform/gateway.dart';
import 'history_store.dart';
import 'sessions.dart';
import 'settings.dart';

typedef Scores = Map<engine.IdentityLane, engine.IdentityScore>;

/// The percentile a score card shows, from the same norms and the same
/// rounding, so a delta is always the difference of two shown numbers.
abstract final class ScoreNorms {
  static bool isLab(engine.IdentityLane lane) =>
      lane == engine.IdentityLane.aerobic || lane == engine.IdentityLane.speed;

  /// The engine's percentile for [vdot], or null when the profile is not
  /// enough. Rendered as returned, never clamped.
  static engine.PercentileEstimate? estimate(
    engine.IdentityLane lane,
    double vdot,
    String source, {
    required ProfileSex sex,
    required int? age,
  }) {
    if (sex != ProfileSex.male && sex != ProfileSex.female) return null;
    final female = sex == ProfileSex.female;
    if (isLab(lane)) {
      return age == null
          ? null
          : engine.FriendFitnessNorms.estimate(vdot, age, female: female);
    }
    return engine.RacePercentileNorms.estimate(
      vdot,
      lane,
      source,
      female: female,
    );
  }

  static int? percentile(
    engine.IdentityLane lane,
    double vdot,
    String source, {
    required ProfileSex sex,
    required int? age,
  }) => estimate(lane, vdot, source, sex: sex, age: age)?.percentile;

  /// "th" for 60, "st" for 21, "th" for 11 to 13.
  static String ordinalSuffix(int n) {
    if (n % 100 >= 11 && n % 100 <= 13) return 'th';
    return switch (n % 10) {
      1 => 'st',
      2 => 'nd',
      3 => 'rd',
      _ => 'th',
    };
  }

  /// Percentile points gained since six weeks ago; null when either side
  /// has no percentile.
  static int? change(
    engine.IdentityScore s, {
    required ProfileSex sex,
    required int? age,
  }) {
    if (s.priorVdot == null) return null;
    final now = percentile(s.lane, s.vdot, s.source, sex: sex, age: age);
    final then = percentile(
      s.lane,
      s.priorVdot!,
      s.priorSource ?? s.source,
      sex: sex,
      age: age,
    );
    return now == null || then == null ? null : now - then;
  }
}

enum ProgressKind { loading, failed, none, baseline, steady, up, down }

/// What Home's hero says: the biggest move in the scores over the last six
/// weeks, or why there is nothing to say yet.
class ProgressHeadline {
  const ProgressHeadline({
    required this.kind,
    required this.title,
    required this.line,
  });
  final ProgressKind kind;
  final String title;
  final String line;

  static const loading = ProgressHeadline(
    kind: ProgressKind.loading,
    title: 'YOUR SCORES',
    line: 'Your scores are loading.',
  );

  static const failed = ProgressHeadline(
    kind: ProgressKind.failed,
    title: 'YOUR SCORES',
    line: "Couldn't load your scores.",
  );

  static ProgressHeadline of(
    Scores scores, {
    required DateTime now,
    required ProfileSex sex,
    required int? age,
  }) {
    if (scores.isEmpty) {
      return const ProgressHeadline(
        kind: ProgressKind.none,
        title: 'SET YOUR SCORES',
        line:
            'Your first runs set them. The dots show which run unlocks which.',
      );
    }
    final since = Fmt.dayMonth(now.subtract(engine.IdentityScores.window));
    engine.IdentityScore? top;
    var topChange = 0;
    var compared = false;
    var profileMissing = true;
    for (final lane in engine.IdentityLane.values) {
      final s = scores[lane];
      if (s == null) continue;
      if (ScoreNorms.percentile(s.lane, s.vdot, s.source, sex: sex, age: age) !=
          null) {
        profileMissing = false;
      }
      final c = ScoreNorms.change(s, sex: sex, age: age);
      if (c == null) continue;
      compared = true;
      if (c.abs() > topChange.abs()) {
        top = s;
        topChange = c;
      }
    }
    if (top == null) {
      return compared
          ? ProgressHeadline(
              kind: ProgressKind.steady,
              title: 'HOLDING STEADY',
              line: 'Since $since. Nothing has moved yet.',
            )
          : ProgressHeadline(
              kind: ProgressKind.baseline,
              title: 'SCORES SET',
              // Ask for the profile only when it is what's missing.
              line: profileMissing
                  ? 'Add your sex and birth year in Settings to compare.'
                  : 'Changes show once you have six weeks of runs.',
            );
    }
    final lane = top.lane.name.toUpperCase();
    final what = _sourceName(top.source);
    if (topChange > 0) {
      return ProgressHeadline(
        kind: ProgressKind.up,
        title: '$lane UP $topChange',
        line: 'Since $since. Your $what on ${_when(top.date, now)} did it.',
      );
    }
    return ProgressHeadline(
      kind: ProgressKind.down,
      title: '$lane DOWN ${-topChange}',
      line:
          'Since $since. Your earlier best has rolled off. '
          '${_bringsBack(top.lane)} brings it back.',
    );
  }

  static String _bringsBack(engine.IdentityLane lane) => switch (lane) {
    engine.IdentityLane.aerobic => 'A hard 5K',
    engine.IdentityLane.speed => 'A clean interval session',
    engine.IdentityLane.mid => 'A 5K or 10K run',
    engine.IdentityLane.long => 'A 15K+ run',
  };

  static String _sourceName(String source) => switch (source) {
    'Cooper test' => '12-minute test',
    '4x4 work pace' => '4x4',
    '1K' => '1K effort',
    'mile' => 'mile effort',
    _ => source,
  };

  /// "Mon" within the last week, else "12 Sep".
  static String _when(DateTime d, DateTime now) => now.difference(d).inDays < 7
      ? Fmt.dayDate(d).split(' ').first
      : Fmt.dayMonth(d);
}

/// The one session Home suggests, why, and how to preset Start for it.
class Recommendation {
  const Recommendation({
    required this.lane,
    required this.reason,
    required this.sessionName,
    required this.apply,
  });
  final engine.IdentityLane lane;
  final String reason;

  /// What the Start button names, e.g. "8 × 400 m".
  final String sessionName;

  /// Presets the Start screen's picked run type.
  final AppSettings Function(AppSettings) apply;

  String get startLabel => 'Start $sessionName';

  /// How long a lane's best can sit before Home calls it stalled.
  static const stalledDays = 14;

  /// A session counts as done this recently, so Home moves on to the next.
  static const doneDays = 3;
  static const longDoneDays = 5;

  /// The lane that has waited longest (a missing one counts as longest, a
  /// dropped one gets a push), skipping lanes whose session is already done.
  static Recommendation of(
    Scores scores,
    List<RunSummary> runs, {
    required DateTime now,
    required ProfileSex sex,
    required int? age,
    Map<String, PresetEdit> presetEdits = const {},
  }) {
    final waits = <engine.IdentityLane, int>{};
    for (final lane in engine.IdentityLane.values) {
      final s = scores[lane];
      if (s == null) {
        waits[lane] = 1000 - lane.index;
        continue;
      }
      final dropped = (ScoreNorms.change(s, sex: sex, age: age) ?? 0) < 0;
      waits[lane] = now.difference(s.date).inDays + (dropped ? 14 : 0);
    }
    final ranked = [...engine.IdentityLane.values]
      ..sort((a, b) {
        final c = waits[b]!.compareTo(waits[a]!);
        return c != 0 ? c : a.index.compareTo(b.index);
      });
    var pick = ranked.firstWhere(
      (l) => _lastDone(l, runs, now) == null,
      orElse: () => ranked.first,
    );
    if (_lastDone(pick, runs, now) != null) {
      // Every lane's session was done recently: the one done longest ago.
      pick = ranked.reduce(
        (a, b) =>
            _lastDone(b, runs, now)!.isBefore(_lastDone(a, runs, now)!) ? b : a,
      );
    }
    final s = scores[pick];
    final stalledWeeks = s == null
        ? null
        : (now.difference(s.date).inDays >= stalledDays
              ? (now.difference(s.date).inDays / 7).round()
              : null);
    return _build(
      pick,
      missing: s == null,
      stalledWeeks: stalledWeeks,
      presetEdits: presetEdits,
    );
  }

  /// Start of the newest recent run that counts as [lane]'s session, or
  /// null when none was done recently.
  static DateTime? _lastDone(
    engine.IdentityLane lane,
    List<RunSummary> runs,
    DateTime now,
  ) {
    DateTime? latest;
    for (final r in runs) {
      if (r.missing) continue;
      final days = lane == engine.IdentityLane.long ? longDoneDays : doneDays;
      if (now.difference(r.start).inDays >= days) continue;
      final counts = switch (lane) {
        engine.IdentityLane.aerobic =>
          r.isFourByFour &&
              (r.spec?.templateId ?? engine.SessionSpec.norwegian4x4Id) ==
                  engine.SessionSpec.norwegian4x4Id,
        engine.IdentityLane.speed => r.spec?.templateId == '400s',
        engine.IdentityLane.mid =>
          r.mode != RecordMode.cooper && r.distanceM >= 5000,
        engine.IdentityLane.long => r.distanceM >= 15000,
      };
      if (counts && (latest == null || r.start.isAfter(latest))) {
        latest = r.start;
      }
    }
    return latest;
  }

  static Recommendation _build(
    engine.IdentityLane lane, {
    required bool missing,
    required int? stalledWeeks,
    required Map<String, PresetEdit> presetEdits,
  }) {
    final name = lane.name.toUpperCase();
    // The name Start shows, with the runner's edits to the preset.
    String named(engine.PresetDef p) =>
        SessionChoice.resolve(p.id, edits: presetEdits)?.name ?? p.name;
    final four = named(engine.SessionCatalogue.fourHundreds);
    final (session, apply, unlock, keep) = switch (lane) {
      engine.IdentityLane.aerobic => (
        engine.SessionCatalogue.norwegian4x4.name,
        _interval(engine.SessionCatalogue.norwegian4x4.id),
        'Your first Norwegian 4x4 sets AEROBIC.',
        'a Norwegian 4x4 this week keeps it climbing',
      ),
      engine.IdentityLane.speed => (
        four,
        _interval(engine.SessionCatalogue.fourHundreds.id),
        'Clean reps in $four set SPEED.',
        '$four this week keeps it climbing',
      ),
      engine.IdentityLane.mid => (
        '5K goal run',
        (AppSettings s) => s.copyWith(goalRun: true, goalId: 'd5000'),
        'MID needs a 5K or 10K run to count.',
        'a 5K goal run this week keeps it climbing',
      ),
      engine.IdentityLane.long => (
        'free run',
        (AppSettings s) =>
            s.copyWith(lastMode: RecordMode.free, goalRun: false),
        'LONG needs a 15K+ run to count.',
        'a 15K+ run this week keeps it climbing',
      ),
    };
    final String reason;
    if (missing) {
      reason = unlock;
    } else if (stalledWeeks != null) {
      reason =
          '$name hasn\'t moved in $stalledWeeks weeks. Try '
          '${lane == engine.IdentityLane.long ? 'a 15K+ run' : session}.';
    } else {
      reason = '$name: $keep.';
    }
    return Recommendation(
      lane: lane,
      reason: reason,
      sessionName: session,
      apply: apply,
    );
  }

  static AppSettings Function(AppSettings) _interval(String id) =>
      (s) => s.copyWith(
        lastMode: RecordMode.intervals,
        goalRun: false,
        sessionId: id,
      );
}
