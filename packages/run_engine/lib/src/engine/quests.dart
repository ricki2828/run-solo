import 'dart:math' as math;

/// The quest engine: one active quest at a time, offered once a month,
/// every target taken from the runner's own history. Pure: no I/O, no clock,
/// the same inputs give the same ids. Progress is never stored; it is folded
/// from the runs every time, so a deleted or re-grouped run cannot leave a
/// stale count.
enum QuestKind {
  trailVisits('trail_visits'),
  trailBest('trail_best'),
  climbBest('climb_best'),
  climbMonth('climb_month'),
  distanceMonth('distance_month');

  const QuestKind(this.wire);

  /// The name on disk and on the wire.
  final String wire;

  static QuestKind? ofWire(Object? w) {
    for (final k in values) {
      if (k.wire == w) return k;
    }
    return null;
  }
}

/// Days a quest runs for, the day it is accepted included (so it ends on
/// the 30th calendar day: accept + 29).
const int kQuestDays = 30;

/// Run ids a trail quest remembers for re-finding its trail.
const int kTrailRunIdsKept = 40;

/// Clocks: every [DateTime] the engine reads or writes (run starts, `now`,
/// `acceptedAt`) is the runner's WALL CLOCK as a UTC-flagged value (see
/// `RunIdentity.localStart`), never a real instant. The app converts its real
/// `now` once at its boundary; mixing the two shifts windows by the zone
/// offset.

/// One run as the quest engine reads it: index-row fields only.
class QuestRun {
  const QuestRun({
    required this.id,
    required this.start,
    required this.distanceM,
    this.climbM,
    this.baro = false,
    this.trailKey,
    this.normMs,
  });

  final String id;

  /// The start as the runner lived it (local wall clock).
  final DateTime start;
  final double distanceM;

  /// Metres climbed; only trusted for quests when [baro] is true.
  final double? climbM;

  /// The elevation came from the barometer.
  final bool baro;

  /// The `TrailGroup.key` this run is grouped to, if any.
  final String? trailKey;

  /// Like-for-like time on its trail (`TrailGroup.normMs`: heat taken out,
  /// length normalised), ms.
  final int? normMs;
}

/// A sane climb on a trail with the runner's best time up it, for
/// `climb_best`. Built by the app from the trail's run files.
class QuestClimb {
  const QuestClimb({
    required this.trailKey,
    required this.idx,
    required this.startM,
    required this.endM,
    required this.gainM,
    required this.bestMs,
    this.runCount = 0,
  });

  final String trailKey;
  final int idx;
  final double startM;
  final double endM;
  final double gainM;
  final int bestMs;

  /// Baro runs behind [bestMs].
  final int runCount;

  double get lengthM => endM - startM;
  double get gradePct => lengthM <= 0 ? 0 : gainM / lengthM * 100;
}

/// A quest: the offer and, once accepted, the active one.
class QuestDef {
  const QuestDef({
    required this.id,
    required this.kind,
    required this.month,
    required this.target,
    required this.baseline,
    this.trailKey,
    this.trailName,
    this.trailRunIds = const [],
    this.climbIdx,
    this.climbLengthM,
    this.climbGainM,
    this.acceptedAt,
    this.endsOn,
    this.source = 'app',
  });

  /// `q_<yyyy-mm>_<kind>_<hash>`; matches the server's `^q_[a-z0-9_-]{1,48}$`.
  final String id;
  final QuestKind kind;

  /// `yyyy-mm` the offer belongs to.
  final String month;

  /// Whole number: runs, metres, km, or seconds (`trail_best`,
  /// `climb_best`).
  final int target;

  /// The runner's own best that the target rests on, same unit as [target].
  final int baseline;
  final String? trailKey;
  final String? trailName;

  /// The runs on the trail when the offer was made (newest last, at most
  /// [kTrailRunIdsKept]). The trail key is `trail:<anchor run id>` and moves
  /// when the anchor is deleted or split off; these let the quest find its
  /// trail again ([Quests.remapTrail]).
  final List<String> trailRunIds;
  final int? climbIdx;
  final int? climbLengthM;
  final int? climbGainM;
  final DateTime? acceptedAt;

  /// `yyyy-mm-dd`, the last day of the window.
  final String? endsOn;

  /// `app` or `coach`.
  final String source;

  bool get accepted => acceptedAt != null;

  QuestDef accept(DateTime at, {String source = 'app'}) {
    final end = DateTime(at.year, at.month, at.day + kQuestDays - 1);
    return QuestDef(
      id: id,
      kind: kind,
      month: month,
      target: target,
      baseline: baseline,
      trailKey: trailKey,
      trailName: trailName,
      trailRunIds: trailRunIds,
      climbIdx: climbIdx,
      climbLengthM: climbLengthM,
      climbGainM: climbGainM,
      acceptedAt: at,
      endsOn: Quests.isoDay(end),
      source: source,
    );
  }

  /// This quest on another trail key (the trail was re-anchored), with a
  /// new [target] and [baseline] when given.
  QuestDef rekeyed(String key, {String? name, int? target, int? baseline}) =>
      QuestDef(
        id: id,
        kind: kind,
        month: month,
        target: target ?? this.target,
        baseline: baseline ?? this.baseline,
        trailKey: key,
        trailName: name ?? trailName,
        trailRunIds: trailRunIds,
        climbIdx: climbIdx,
        climbLengthM: climbLengthM,
        climbGainM: climbGainM,
        acceptedAt: acceptedAt,
        endsOn: endsOn,
        source: source,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.wire,
    'month': month,
    'target': target,
    'baseline': baseline,
    'trailKey': ?trailKey,
    'trailName': ?trailName,
    if (trailRunIds.isNotEmpty) 'trailRunIds': trailRunIds,
    'climbIdx': ?climbIdx,
    'climbLengthM': ?climbLengthM,
    'climbGainM': ?climbGainM,
    if (acceptedAt != null) 'acceptedAt': acceptedAt!.toIso8601String(),
    'endsOn': ?endsOn,
    'source': source,
  };

  static QuestDef? fromJson(Object? j) {
    if (j is! Map) return null;
    final kind = QuestKind.ofWire(j['kind']);
    final id = j['id'], month = j['month'];
    final target = j['target'], baseline = j['baseline'];
    if (kind == null ||
        id is! String ||
        month is! String ||
        target is! int ||
        baseline is! int) {
      return null;
    }
    final at = j['acceptedAt'];
    final trailKey = j['trailKey'], trailName = j['trailName'];
    final ends = j['endsOn'];
    return QuestDef(
      id: id,
      kind: kind,
      month: month,
      target: target,
      baseline: baseline,
      trailKey: trailKey is String ? trailKey : null,
      trailName: trailName is String ? trailName : null,
      trailRunIds: [
        if (j['trailRunIds'] is List)
          for (final r in j['trailRunIds'] as List)
            if (r is String) r,
      ],
      climbIdx: j['climbIdx'] is int ? j['climbIdx']! as int : null,
      climbLengthM: j['climbLengthM'] is int ? j['climbLengthM']! as int : null,
      climbGainM: j['climbGainM'] is int ? j['climbGainM']! as int : null,
      acceptedAt: at is String ? _asWall(DateTime.tryParse(at)) : null,
      endsOn: ends is String ? ends : null,
      source: j['source'] == 'coach' ? 'coach' : 'app',
    );
  }

  /// An older build saved `acceptedAt` from the phone's clock (no `Z`): the
  /// fields were already the runner's wall clock, so keep them and flag the
  /// value UTC, the clock the engine now runs on.
  static DateTime? _asWall(DateTime? d) => d == null || d.isUtc
      ? d
      : DateTime.utc(
          d.year,
          d.month,
          d.day,
          d.hour,
          d.minute,
          d.second,
          d.millisecond,
        );

  // ---- Copy (plain, casual, no em dashes) --------------------------------

  String get _trail => trailName == null || trailName!.trim().isEmpty
      ? 'your trail'
      : trailName!.trim();

  String get _trailCaps => _trail.toUpperCase();

  /// "SADDLE ×5", the big words on the card, the toast and the Moment.
  String get title => switch (kind) {
    QuestKind.trailVisits => '$_trailCaps ×$target',
    QuestKind.trailBest => 'BEAT ${Quests.fmtTime(target)} ON $_trailCaps',
    QuestKind.climbBest => 'THE ${_climbName()} CLIMB, $_trailCaps',
    QuestKind.climbMonth => '${Quests.fmtInt(target)} M UP',
    QuestKind.distanceMonth => '${Quests.fmtInt(target)} KM',
  };

  /// One calm line under the title.
  String get line => switch (kind) {
    QuestKind.trailVisits =>
      '${Quests.word(target)} runs of $_trail in $kQuestDays days. '
          'Your best $kQuestDays days so far: $baseline '
          '${baseline == 1 ? 'run' : 'runs'}.',
    QuestKind.trailBest =>
      'Your best on $_trail, heat taken out. A hot day still counts.',
    QuestKind.climbBest =>
      'Your best up it is ${Quests.fmtTime(baseline)}. '
          '${climbGainM ?? 0} m up, ${_grade()}%.',
    QuestKind.climbMonth =>
      'Climb ${Quests.fmtInt(target)} m in $kQuestDays days. '
          'Your best $kQuestDays days so far: ${Quests.fmtInt(baseline)} m.',
    QuestKind.distanceMonth =>
      'Run ${Quests.fmtInt(target)} km in $kQuestDays days. '
          'Your best $kQuestDays days so far: ${Quests.fmtInt(baseline)} km.',
  };

  /// What the Moment says once it is done, [days] after it was accepted.
  String doneLine(int days) => switch (kind) {
    QuestKind.trailVisits =>
      '${Quests.word(target)} runs of $_trail in $days '
          '${days == 1 ? 'day' : 'days'}. Your busiest month on it.',
    QuestKind.trailBest => 'A new best on $_trail, heat taken out.',
    QuestKind.climbBest => 'Your best ever up the climb on $_trail.',
    QuestKind.climbMonth =>
      '${Quests.fmtInt(target)} m climbed in $days '
          '${days == 1 ? 'day' : 'days'}. Your biggest month yet.',
    QuestKind.distanceMonth =>
      '${Quests.fmtInt(target)} km in $days '
          '${days == 1 ? 'day' : 'days'}. Your biggest month yet.',
  };

  /// What the recorder says when the quest is done mid-run: short, plain, ending "Quest done."
  /// (`trail_best` is never done live; its line is only here for completeness.)
  String get liveLine => switch (kind) {
    QuestKind.trailVisits =>
      '$_spokenTrail number ${target <= 10 ? Quests.word(target).toLowerCase() : target}. '
          'Quest done.',
    QuestKind.trailBest => 'A new best on $_spokenTrail. Quest done.',
    QuestKind.climbBest => 'Best ever up the climb. Quest done.',
    QuestKind.climbMonth => '$target metres climbed this month. Quest done.',
    QuestKind.distanceMonth => '$target kilometres run this month. Quest done.',
  };

  /// The trail name as it is said: plain words only, at most three of them.
  String get _spokenTrail {
    if (trailName == null || trailName!.trim().isEmpty) return 'Your trail';
    final words = _trail
        .replaceAll(RegExp(r"[^\p{L}\p{N}' -]", unicode: true), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .take(3)
        .toList();
    if (words.isEmpty) return 'Your trail';
    return words.join(' ');
  }

  String _climbName() {
    final len = climbLengthM;
    if (len == null) return '';
    final km = len / 1000;
    return '${km.toStringAsFixed(1)} K';
  }

  String _grade() {
    final len = climbLengthM, gain = climbGainM;
    if (len == null || gain == null || len <= 0) return '0';
    return (gain / len * 100).round().toString();
  }
}

/// How far a quest has got.
class QuestProgress {
  const QuestProgress({
    required this.value,
    required this.target,
    required this.contributingRunIds,
    required this.complete,
    this.completedByRunId,
    this.bestMs,
  });

  /// Runs, metres, or km (the same unit as [QuestDef.target]) so far.
  /// `trail_best` and `climb_best`: 1 when beaten, else 0.
  final num value;
  final int target;
  final List<String> contributingRunIds;
  final bool complete;

  /// The run that crossed the line.
  final String? completedByRunId;

  /// `trail_best` and `climb_best`: the best like-for-like time in the
  /// window so far, ms.
  final int? bestMs;

  double get fraction => target <= 0 ? 0 : (value / target).clamp(0, 1);
}

abstract final class Quests {
  /// "2026-11".
  static String monthOf(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}';

  static String isoDay(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static DateTime? parseDay(String? s) {
    final m = s == null
        ? null
        : RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(s);
    return m == null
        ? null
        : DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  }

  /// Whole days between two calendar dates (DST-safe).
  static int daysBetween(DateTime a, DateTime b) => DateTime.utc(
    b.year,
    b.month,
    b.day,
  ).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

  /// 1,000.
  static String fmtInt(num n) {
    final s = n.round().toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }

  /// 41:12, or 1:02:09 past the hour. [seconds] whole.
  static String fmtTime(int seconds) {
    final h = seconds ~/ 3600, m = seconds % 3600 ~/ 60, s = seconds % 60;
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
  }

  static const _words = [
    'Zero', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight',
    'Nine', 'Ten', //
  ];

  /// "Five" for 5, digits past ten.
  static String word(int n) => n >= 0 && n < _words.length ? _words[n] : '$n';

  /// A short stable hash for ids: 4 hex chars of FNV-1a over [s].
  static String hash(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xffffffff;
    }
    return (h & 0xffff).toRadixString(16).padLeft(4, '0');
  }

  static String idOf(String month, QuestKind kind, [String seed = '']) =>
      'q_${month}_${kind.wire}_${hash('${kind.wire}|$seed')}';

  /// The most [QuestRun] value inside any [kQuestDays]-day window, where each
  /// run counts [value] of itself.
  static double best30(
    Iterable<QuestRun> runs,
    double Function(QuestRun) value,
  ) {
    final sorted = [...runs]..sort((a, b) => a.start.compareTo(b.start));
    var best = 0.0, sum = 0.0, lo = 0;
    for (var hi = 0; hi < sorted.length; hi++) {
      sum += value(sorted[hi]);
      while (daysBetween(sorted[lo].start, sorted[hi].start) >= kQuestDays) {
        sum -= value(sorted[lo]);
        lo++;
      }
      best = math.max(best, sum);
    }
    return best;
  }

  /// Up to three offers, best first. Deterministic. [closed] is the finished
  /// quests, newest last: the kind and trail of the latest is never offered
  /// again. [climbs] are the sane climbs on trails (empty when not built).
  /// [trailNames] maps `TrailGroup.key` to the name shown.
  static List<QuestDef> candidates(
    List<QuestRun> runs,
    DateTime now, {
    List<QuestDef> closed = const [],
    List<QuestClimb> climbs = const [],
    Map<String, String> trailNames = const {},
  }) {
    final past = [
      for (final r in runs)
        if (!r.start.isAfter(now)) r,
    ]..sort((a, b) => a.start.compareTo(b.start));
    // First-week value comes from the firsts, not from a quest.
    if (past.length < 3) return const [];
    final month = monthOf(now);
    final out = <QuestDef>[];

    // The most-run trail of the last 120 days (3 runs or more).
    final since120 = now.subtract(const Duration(days: 120));
    final counts = <String, int>{};
    final lastRun = <String, DateTime>{};
    for (final r in past) {
      final k = r.trailKey;
      if (k == null || r.start.isBefore(since120)) continue;
      counts[k] = (counts[k] ?? 0) + 1;
      lastRun[k] = r.start;
    }
    String? top;
    for (final e in counts.entries) {
      if (e.value < 3) continue;
      if (top == null ||
          e.value > counts[top]! ||
          (e.value == counts[top] && lastRun[e.key]!.isAfter(lastRun[top]!)) ||
          (e.value == counts[top] &&
              lastRun[e.key] == lastRun[top] &&
              e.key.compareTo(top) < 0)) {
        top = e.key;
      }
    }

    if (top != null) {
      final onTrail = [
        for (final r in past)
          if (r.trailKey == top) r,
      ];
      final name = trailNames[top];
      final remember = [
        for (final r
            in onTrail.reversed.take(kTrailRunIdsKept).toList().reversed)
          r.id,
      ];
      final most = best30(onTrail, (_) => 1).round();
      out.add(
        QuestDef(
          id: idOf(month, QuestKind.trailVisits, top),
          kind: QuestKind.trailVisits,
          month: month,
          target: math.max(3, most + 1),
          baseline: most,
          trailKey: top,
          trailName: name,
          trailRunIds: remember,
        ),
      );

      // climb_best needs the per-run climb times, which the app only builds
      // from run files; PR2 passes no [climbs], so it is not offered yet.
      final topClimbs = [
        for (final c in climbs)
          if (c.trailKey == top &&
              c.runCount >= 3 &&
              c.lengthM >= 300 &&
              c.lengthM <= 3000 &&
              c.gainM >= 15)
            c,
      ]..sort((a, b) => b.gainM.compareTo(a.gainM));
      if (topClimbs.isNotEmpty) {
        final c = topClimbs.first;
        final secs = c.bestMs ~/ 1000;
        out.add(
          QuestDef(
            id: idOf(month, QuestKind.climbBest, '$top|${c.idx}'),
            kind: QuestKind.climbBest,
            month: month,
            target: secs,
            baseline: secs,
            trailKey: top,
            trailName: name,
            trailRunIds: remember,
            climbIdx: c.idx,
            climbLengthM: c.lengthM.round(),
            climbGainM: c.gainM.round(),
          ),
        );
      }

      final times = [
        for (final r in onTrail)
          if (r.normMs != null) r.normMs!,
      ];
      if (times.length >= 3) {
        // Floor: a run only a hair slower than the best must not complete it.
        final secs = times.reduce(math.min) ~/ 1000;
        out.add(
          QuestDef(
            id: idOf(month, QuestKind.trailBest, top),
            kind: QuestKind.trailBest,
            month: month,
            target: secs,
            baseline: secs,
            trailKey: top,
            trailName: name,
            trailRunIds: remember,
          ),
        );
      }
    }

    // climb_month: half or more of the last 60 days' runs have barometer
    // elevation.
    final since60 = now.subtract(const Duration(days: 60));
    final last60 = [
      for (final r in past)
        if (!r.start.isBefore(since60)) r,
    ];
    final baroRuns = [
      for (final r in past)
        if (r.baro && r.climbM != null) r,
    ];
    if (last60.isNotEmpty &&
        last60.where((r) => r.baro).length * 2 >= last60.length &&
        baroRuns.isNotEmpty) {
      final bestClimb = best30(baroRuns, (r) => r.climbM!);
      final target = math.max(300, (bestClimb * 1.1 / 50).ceil() * 50);
      out.add(
        QuestDef(
          id: idOf(month, QuestKind.climbMonth),
          kind: QuestKind.climbMonth,
          month: month,
          target: target,
          baseline: bestClimb.round(),
        ),
      );
    }

    // distance_month: always possible from the 3rd run.
    final bestKm = best30(past, (r) => r.distanceM / 1000);
    out.add(
      QuestDef(
        id: idOf(month, QuestKind.distanceMonth),
        kind: QuestKind.distanceMonth,
        month: month,
        target: math.max(10, (bestKm * 1.1 / 5).ceil() * 5),
        baseline: bestKm.round(),
      ),
    );

    // Never the same kind and trail as the quest that just ended, unless
    // that leaves nothing to offer (a runner with only distance_month).
    final last = closed.isEmpty ? null : closed.last;
    final fresh = [
      for (final d in out)
        if (last == null || d.kind != last.kind || d.trailKey != last.trailKey)
          d,
    ];
    return (fresh.isEmpty ? out : fresh).take(3).toList();
  }

  /// A trail quest whose trail has re-keyed or been split found again. The
  /// trail key is `trail:<anchor run id>`, so deleting the anchor changes
  /// it, and splitting the anchor off leaves it as a one-run group still
  /// holding the old key. Every run the quest remembers votes for the key it
  /// is on now; the quest moves when another key holds more of them than its
  /// own key does, and at least two of them (or most of those remembered),
  /// so one stray run never moves it. `trail_best` is re-based on the best
  /// like-for-like time before it was accepted on the new key, since times
  /// are normalised to the new anchor's length. Returns [def] itself when it
  /// stays.
  static QuestDef remapTrail(
    QuestDef def,
    List<QuestRun> runs,
    Map<String, String> trailNames,
  ) {
    final key = def.trailKey;
    if (key == null) return def;
    final remembered = def.trailRunIds.toSet();
    final votes = <String, int>{};
    for (final r in runs) {
      final k = r.trailKey;
      if (k != null && remembered.contains(r.id)) {
        votes[k] = (votes[k] ?? 0) + 1;
      }
    }
    if (votes.isEmpty) return def;
    final entries = votes.entries.toList()
      ..sort((a, b) {
        final c = b.value.compareTo(a.value);
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    final top = entries.first;
    final own = votes[key] ?? 0;
    if (top.key == key ||
        top.value <= own ||
        !(top.value >= 2 || top.value * 2 > remembered.length)) {
      return def;
    }
    final next = entries.first.key;
    int? target;
    if (def.kind == QuestKind.trailBest) {
      final at = def.acceptedAt;
      final before = [
        for (final r in runs)
          if (r.trailKey == next &&
              r.normMs != null &&
              (at == null || r.start.isBefore(at)))
            r.normMs!,
      ];
      if (before.isNotEmpty) target = before.reduce(math.min) ~/ 1000;
    }
    return def.rekeyed(
      next,
      name: trailNames[next],
      target: target,
      baseline: target,
    );
  }

  /// Progress of an accepted [def] over [runs]. [climbTimes] is the time (ms)
  /// each run took on the quest's climb, for `climb_best`.
  static QuestProgress progress(
    QuestDef def,
    List<QuestRun> runs, {
    Map<String, int> climbTimes = const {},
  }) {
    final at = def.acceptedAt;
    final end = parseDay(def.endsOn);
    if (at == null || end == null) {
      return QuestProgress(
        value: 0,
        target: def.target,
        contributingRunIds: const [],
        complete: false,
      );
    }
    final inWindow = [
      for (final r in runs)
        if (!r.start.isBefore(at) && daysBetween(r.start, end) >= 0) r,
    ]..sort((a, b) => a.start.compareTo(b.start));

    final ids = <String>[];
    num value = 0;
    String? by;
    int? bestMs;
    var complete = false;

    void add(QuestRun r, num v) {
      ids.add(r.id);
      value += v;
      if (!complete && value >= def.target) {
        complete = true;
        by = r.id;
      }
    }

    switch (def.kind) {
      case QuestKind.trailVisits:
        for (final r in inWindow) {
          if (r.trailKey == def.trailKey) add(r, 1);
        }
      case QuestKind.climbMonth:
        for (final r in inWindow) {
          if (r.baro && r.climbM != null && r.climbM! > 0) add(r, r.climbM!);
        }
        value = value.round();
      case QuestKind.distanceMonth:
        for (final r in inWindow) {
          if (r.distanceM > 0) add(r, r.distanceM / 1000);
        }
        value = (value * 10).floor() / 10;
      case QuestKind.trailBest:
        for (final r in inWindow) {
          final t = r.normMs;
          if (r.trailKey != def.trailKey || t == null) continue;
          ids.add(r.id);
          bestMs = bestMs == null ? t : math.min(bestMs, t);
          if (!complete && t < def.target * 1000) {
            complete = true;
            by = r.id;
          }
        }
        value = complete ? 1 : 0;
      case QuestKind.climbBest:
        for (final r in inWindow) {
          final t = climbTimes[r.id];
          if (r.trailKey != def.trailKey || t == null) continue;
          ids.add(r.id);
          bestMs = bestMs == null ? t : math.min(bestMs, t);
          if (!complete && t < def.target * 1000) {
            complete = true;
            by = r.id;
          }
        }
        value = complete ? 1 : 0;
    }
    return QuestProgress(
      value: value,
      target: def.target,
      contributingRunIds: ids,
      complete: complete,
      completedByRunId: by,
      bestMs: bestMs,
    );
  }

  /// The window has closed without the quest being done.
  static bool expired(QuestDef def, DateTime now) {
    final end = parseDay(def.endsOn);
    return end != null && daysBetween(end, now) > 0;
  }

  /// Days left including today; 0 once the window has closed.
  static int daysLeft(QuestDef def, DateTime now) {
    final end = parseDay(def.endsOn);
    return end == null ? 0 : math.max(0, daysBetween(now, end) + 1);
  }

  /// What the recorder needs to say "quest done" live, or null when there is
  /// no live line: metres still to climb or run (`climb_month`,
  /// `distance_month`), 1 for the last trail visit, the target time in ms
  /// for `climb_best`, null for `trail_best` (its heat factor is only final
  /// at finalise, so it completes on the result screen).
  static double? liveRemaining(QuestDef def, QuestProgress p) {
    if (p.complete) return null;
    return switch (def.kind) {
      QuestKind.climbMonth => (def.target - p.value).toDouble(),
      QuestKind.distanceMonth => (def.target - p.value) * 1000,
      QuestKind.trailVisits => p.value >= def.target - 1 ? 1 : null,
      QuestKind.climbBest => def.target * 1000.0,
      QuestKind.trailBest => null,
    };
  }
}
