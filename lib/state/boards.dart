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
  });
  final String boardKey;
  final String label;
  final bool pb;

  @override
  String toString() => '${pb ? 'PB ' : ''}$label';
}

class Boards {
  Boards._(this._inputs, this._names, {required this.updating})
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
      updating: list.any((e) => e.derived == null && !e.derivedFailed),
    );
  }

  static final Boards empty = Boards._(const {}, const {}, updating: false);

  final Map<String, engine.BoardInput> _inputs;

  /// Interval comparison key → the session's name, for labels.
  final Map<String, String> _names;
  final bool updating;
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
    final mine = engine.Leaderboards.membership(run).keys.toList()
      ..sort((a, b) => _order(run, a).compareTo(_order(run, b)));
    final pbs = [
      for (final k in mine)
        if (then[k]!.length >= 2 && then[k]!.rankOf(runId) == 1)
          BoardChip(
            boardKey: k,
            label: _pbLabel(k, then[k]!, units, names),
            pb: true,
          ),
    ];
    if (pbs.isNotEmpty) return pbs.take(2).toList();
    if (mine.isEmpty) return const [];
    final k = mine.first;
    final board = then[k]!;
    return [
      BoardChip(
        boardKey: k,
        label: board.length == 1
            ? 'First ${_one(k, names)} on your board'
            : '#${board.rankOf(runId)} of ${board.length} '
                  '${_many(k, names)} · ${_gap(k, board, runId, units)}',
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
    _ when engine.ComparisonKey.isParkrun(key) => names.parkrun,
    _ => switch (engine.BestEffortDistance.ofKey(key)) {
      engine.BestEffortDistance.km1 => '1 km',
      engine.BestEffortDistance.mile => 'mile',
      engine.BestEffortDistance.k5 => '5K',
      engine.BestEffortDistance.k10 => '10K',
      null => _names[key] ?? 'session',
    },
  };

  String _many(String key, engine.EventNames names) => switch (key) {
    _ when key == engine.ComparisonKey.cooper => 'tests',
    _ when engine.ComparisonKey.isParkrun(key) => names.parkrunPlural,
    _ => switch (engine.BestEffortDistance.ofKey(key)) {
      engine.BestEffortDistance.km1 => '1 km runs',
      engine.BestEffortDistance.mile => 'miles',
      engine.BestEffortDistance.k5 => '5Ks',
      engine.BestEffortDistance.k10 => '10Ks',
      null => '${_names[key] ?? 'session'} sessions',
    },
  };

  /// The board's value as a runner reads it: a time, a pace, or the VO2
  /// estimate (which says so).
  static String value(engine.Leaderboard b, double metric, Units units) =>
      switch (b.kind) {
        engine.BoardKind.bestEffort ||
        engine.BoardKind.course => Fmt.clock((metric * 1000).round()),
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
      engine.BoardKind.bestEffort || engine.BoardKind.course => () {
        final s = (mine - best).round();
        return s < 60
            ? '$s s off your best'
            : '${Fmt.clock(s * 1000)} off your best';
      }(),
      engine.BoardKind.interval =>
        '${Fmt.deltaSecondsVsLast(mine, best, units).abs()} '
            's/${units == Units.mi ? 'mi' : 'km'} off your best',
      engine.BoardKind.cooper =>
        'VO2 est. ${(best - mine).toStringAsFixed(1)} below your best',
    };
  }
}
