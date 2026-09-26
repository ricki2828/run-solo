import 'dart:async';

import 'package:flutter/material.dart';

import '../app/event_names.dart';
import '../app/services.dart';
import '../state/boards.dart';
import '../state/history_store.dart';
import '../theme/theme.dart';
import 'rank_chip.dart';

/// A10.3: the run's board chips in the result's chip slot (verdict, Laps /
/// Free summary, 12-minute test, event result). At most two; a PB is Arc and
/// plays M5 only straight after the run ([justFinished]). Nothing shows
/// until the boards are folded, and nothing when the run is on no board.
class BoardChips extends StatefulWidget {
  const BoardChips({
    super.key,
    required this.runId,
    this.justFinished = false,
    this.onTapBoard,
  });

  final String runId;
  final bool justFinished;

  /// Opens that board (LB3 Boards tab); null = chips are not tappable.
  final void Function(String boardKey)? onTapBoard;

  @override
  State<BoardChips> createState() => _BoardChipsState();
}

class _BoardChipsState extends State<BoardChips> {
  Boards? _boards;
  RunStore? _history;
  Timer? _pendingText;

  /// "Checking your boards" only once the wait is noticeable (lead 26-Sep):
  /// a batch that lands within this shows the final chip straight away.
  static const Duration pendingTextAfter = Duration(seconds: 4);
  bool _showPending = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_history != null) return;
    _history = AppServices.of(context).history;
    _history!.derivedChanged.addListener(_fold);
    _pendingText = Timer(pendingTextAfter, () {
      if (mounted) setState(() => _showPending = true);
    });
    _fold();
  }

  /// Folds now and again each time a batch lands, however late, until no
  /// run is missing its best efforts. A PB that lands while the screen is
  /// open plays M5 then; if it lands after, the next view shows it still.
  Future<void> _fold() async {
    final history = _history;
    if (history == null) return;
    final boards = await history.boards();
    if (!mounted) return;
    setState(() => _boards = boards);
    if (!boards.updating) {
      history.derivedChanged.removeListener(_fold);
      _pendingText?.cancel();
    }
  }

  @override
  void dispose() {
    _history?.derivedChanged.removeListener(_fold);
    _pendingText?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final services = AppServices.of(context);
    final settings = services.settings.settings;
    final chips = _boards?.chipsFor(
      widget.runId,
      units: settings.units,
      names: kEventNames,
    );
    final shown = [
      for (final c in chips ?? const <BoardChip>[])
        if (!c.pending || _showPending) c,
    ];
    if (shown.isEmpty) return const SizedBox.shrink();
    return Column(
      key: const ValueKey('board-chips'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, c) in shown.indexed) ...[
          // #71 P3: a gap between two stacked PB chips.
          if (i > 0) const SizedBox(height: Space.x8),
          RankChip(
            // A new State when a pending chip becomes a PB, so M5 plays.
            key: ValueKey('chip-${c.boardKey}-${c.pb}-${c.pending}'),
            label: c.label,
            pb: c.pb,
            celebrate: widget.justFinished && c == shown.first,
            haptics: settings.haptics,
            onTap: widget.onTapBoard == null || c.pending
                ? null
                : () => widget.onTapBoard!(c.boardKey),
          ),
        ],
        const SizedBox(height: Space.x4),
      ],
    );
  }
}
