/// Personal leaderboards in the app (LB3; design addendum A10.2, A10.3):
/// the engine's LB2 fold over the index entries, and the rank / PB chips a
/// result screen shows. One fold for every screen (verdict, Laps / Free
/// summary, 12-minute test, the event result, the Boards tab).
library;

import 'package:flutter/foundation.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../platform/gateway.dart';
import 'run_index.dart';

/// One A10.3 chip: which board, what it says, and whether it is a PB (Arc,
/// fires M5) or a hairline rank / first entry.
@immutable
class BoardChip {
  const BoardChip({
    required this.boardKey,
    required this.label,
    required this.pb,
    this.pending = false,
  });
  final String boardKey;
  final String label;
  final bool pb;

  /// The best-effort boards are still being built (this run's, or others'
  /// after an engine bump): a hairline "Checking your boards" that never
  /// claims a PB until they are complete (#71 review P1).
  final bool pending;

  static const String pendingLabel = 'Checking your boards';

  @override
  String toString() => '${pb ? 'PB ' : ''}${pending ? '… ' : ''}$label';
}

class Boards {
  Boards._(this._inputs, this._names, {required this.pendingIds})
    : byKey = engine.Leaderboards.fold(_inputs.values);

  /// The boards over [entries] (the index, or the memory store's
  /// equivalent). [updating]: some entry has no derived data yet, so the
  /// best-effort boards may be missing runs ("Updating your boards").
  factory Boards.fold(Iterable<RunIndexEntry> entries) {
    final list = entries.toList();
    final names = <String, String>{};
    for (final e in list) {
      final k = e.comparisonKey;
      if (k == null) continue;
      final name =
          e.row?.session?.name ?? engine.SessionCatalogue.ownerOfKey(k)?.name;
      if (name != null) names[k] = name;
    }
    return Boards._(
      {for (final e in list) e.id: e.boardInput()},
      names,
      pendingIds: {
        for (final e in list)
          if (!(e.derived?.isCurrent ?? false) && !e.derivedFailed) e.id,
      },
    );
  }

  static final Boards empty = Boards._(const {}, const {}, pendingIds: {});

  final Map<String, engine.BoardInput> _inputs;

  /// Interval comparison key → the session's name, for labels.
  final Map<String, String> _names;

  /// Runs whose derived data (best efforts) is not built yet.
  final Set<String> pendingIds;

  /// Some run has no derived data yet, so the best-effort boards may be
  /// missing runs ("Updating your boards").
  bool get updating => pendingIds.isNotEmpty;

  /// [runId]'s own best efforts are not built yet.
  bool pendingFor(String runId) => pendingIds.contains(runId);
  final Map<String, engine.Leaderboard> byKey;

  bool get isEmpty => byKey.isEmpty;

  /// A10.3 chips for [runId], ranked as each board stood that day (runs up
  /// to and including it), so an old best stays a best:
  /// - PB chips first, longest distance first, at most two;
  /// - without a PB, one chip for the run's main board: the rank, or
  ///   "First … on your board" for a board's first entry.
  List<BoardChip> chipsFor(
    String runId, {
    required Units units,
    required engine.EventNames names,
  }) {
    final run = _inputs[runId];
    if (run == null) return const [];
    final then = engine.Leaderboards.fold(
      _inputs.values.where((i) => !i.date.isAfter(run.date)),
    );
    // While any best efforts are missing, the be:* boards are incomplete:
    // a new run could outrank runs that are not on them yet (#71 P1-2), and
    // this run may not be on them at all (P1-1). No be:* chip until then.
    final waiting = updating;
    final mine =
        engine.Leaderboards.membership(run).keys
            .where(
              (k) =>
                  !waiting ||
                  !k.startsWith(engine.ComparisonKey.reservedBoardPrefix),
            )
            .toList()
          ..sort((a, b) => _order(run, a).compareTo(_order(run, b)));
    bool isPb(String k) {
      final b = then[k]!;
      if (b.length < 2) return false;
      if (b.rankOf(runId) == 1) return true;
      // The 4x4's New best keeps its old meaning (#71 P3): the best of the
      // 365 days up to the run, as the verdict's bestIn365Days has it.
      if (k != engine.ComparisonKey.norwegian4x4) return false;
      final from = run.date.subtract(const Duration(days: 365));
      final year = engine.Leaderboards.fold(
        _inputs.values.where(
          (i) => !i.date.isAfter(run.date) && !i.date.isBefore(from),
        ),
      )[k];
      return year != null && year.length >= 2 && year.rankOf(runId) == 1;
    }

    final pbs = [
      for (final k in mine)
        if (isPb(k))
          BoardChip(
            boardKey: k,
            label: _pbLabel(k, then[k]!, units, names),
            pb: true,
          ),
    ];
    if (pbs.isNotEmpty) return pbs.take(2).toList();
    if (mine.isEmpty) {
      return waiting
          ? const [
              BoardChip(
                boardKey: '',
                label: BoardChip.pendingLabel,
                pb: false,
                pending: true,
              ),
            ]
          : const [];
    }
    final k = mine.first;
    final board = then[k]!;
    return [
      BoardChip(
        boardKey: k,
        label: board.length == 1
            ? 'First ${_one(k, names)} on your board'
            : '#${board.rankOf(runId)} of ${board.length} '
                  '${_many(k, names)} · ${_keep(_gap(k, board, runId, units))}',
        pb: false,
      ),
    ];
  }

  /// A run's main board first: its own session or test board, the event
  /// course, then best efforts, longest first.
  static int _order(engine.BoardInput run, String key) {
    if (key == run.comparisonKey) return -1 << 40; // before any distance
    return -(engine.Leaderboards.metresOf(key) ?? 0).round();
  }

  String _one(String key, engine.EventNames names) => switch (key) {
    _ when key == engine.ComparisonKey.cooper => 'test',
    _ when engine.BestTimeWindow.ofKey(key) != null =>
      '${engine.BestTimeWindow.ofKey(key)!.seconds ~/ 60} min',
    _ when engine.ComparisonKey.isGoal(key) => 'goal',
    _ when engine.ComparisonKey.isParkrun(key) => names.parkrun,
    _ => switch (engine.BestEffortDistance.ofKey(key)) {
      engine.BestEffortDistance.km1 => '1 km',
      engine.BestEffortDistance.mile => 'mile',
      engine.BestEffortDistance.k5 => '5K',
      engine.BestEffortDistance.k10 => '10K',
      engine.BestEffortDistance.half => 'half marathon',
      engine.BestEffortDistance.marathon => 'marathon',
      null => _names[key] ?? 'session',
    },
  };

  String _many(String key, engine.EventNames names) => switch (key) {
    _ when key == engine.ComparisonKey.cooper => 'tests',
    _ when engine.BestTimeWindow.ofKey(key) != null =>
      '${engine.BestTimeWindow.ofKey(key)!.seconds ~/ 60} min runs',
    _ when engine.ComparisonKey.isGoal(key) => 'goals',
    _ when engine.ComparisonKey.isParkrun(key) => names.parkrunPlural,
    _ => switch (engine.BestEffortDistance.ofKey(key)) {
      engine.BestEffortDistance.km1 => '1 km runs',
      engine.BestEffortDistance.mile => 'miles',
      engine.BestEffortDistance.k5 => '5Ks',
      engine.BestEffortDistance.k10 => '10Ks',
      engine.BestEffortDistance.half => 'half marathons',
      engine.BestEffortDistance.marathon => 'marathons',
      null => _sessionPlural(_names[key]),
    },
  };

  /// A10.3's "Norwegian 4x4s": a name ending in a digit takes an s, one
  /// ending in s stands as it is ("Yasso 800s"), anything else is "…
  /// sessions" ("8 × 400 m sessions").
  static String _sessionPlural(String? name) {
    if (name == null) return 'sessions';
    final last = name.codeUnitAt(name.length - 1);
    if (last >= 0x30 && last <= 0x39) return '${name}s';
    if (name.endsWith('s')) return name;
    return '$name sessions';
  }

  /// Keeps "21 s/km off your best" on one line: a no-break space before
  /// the unit and a word joiner after the slash.
  static String _keep(String s) =>
      s.replaceAll(' s/', '\u00A0s/\u2060').replaceAll(' s off', '\u00A0s off');

  /// The board's value as a runner reads it: a time, a pace, or the VO2
  /// estimate (which says so).
  static String value(engine.Leaderboard b, double metric, Units units) =>
      switch (b.kind) {
        engine.BoardKind.bestEffort ||
        engine.BoardKind.course ||
        engine.BoardKind.goalDistance => Fmt.clock((metric * 1000).round()),
        engine.BoardKind.distanceInTime => Fmt.distance(metric, units),
        engine.BoardKind.interval => Fmt.paceUnit(metric, units),
        engine.BoardKind.cooper => 'VO2 est. ${metric.round()}',
      };

  String _pbLabel(
    String key,
    engine.Leaderboard b,
    Units units,
    engine.EventNames names,
  ) => key == engine.ComparisonKey.cooper
      ? 'New best test · ${value(b, b.pb!.metric, units)}'
      : 'New best ${_one(key, names)} · ${value(b, b.pb!.metric, units)}';

  static String _gap(
    String key,
    engine.Leaderboard b,
    String runId,
    Units units,
  ) {
    final mine = b.ranked.firstWhere((r) => r.runId == runId).metric;
    final best = b.pb!.metric;
    return switch (b.kind) {
      engine.BoardKind.distanceInTime => () {
        final m = best - mine;
        return m < 10
            ? 'level with your best'
            : '${Fmt.distance(m, units)} short of your best';
      }(),
      engine.BoardKind.bestEffort ||
      engine.BoardKind.course ||
      engine.BoardKind.goalDistance => () {
        final s = (mine - best).round();
        if (s <= 0) return 'level with your best';
        return s < 60
            ? '$s s off your best'
            : '${Fmt.clock(s * 1000)} off your best';
      }(),
      engine.BoardKind.interval => () {
        final n = Fmt.deltaSecondsVsLast(mine, best, units).abs();
        return n == 0
            ? 'level with your best'
            : '$n s/${units == Units.mi ? 'mi' : 'km'} off your best';
      }(),
      engine.BoardKind.cooper => () {
        final d = ((best - mine) * 10).round() / 10;
        return d <= 0
            ? 'level with your best'
            : 'VO2 est. ${d.toStringAsFixed(1)} below your best';
      }(),
    };
  }
}
