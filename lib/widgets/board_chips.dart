import 'dart:async';

import 'package:flutter/material.dart';

import '../app/event_names.dart';
import '../app/services.dart';
import '../state/boards.dart';
import '../state/history_store.dart';
import '../state/quests/quest_chip.dart';
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
  QuestChip? _quest;
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
    final quest = await _questChip(history);
    if (!mounted) return;
    setState(() {
      _boards = boards;
      _quest = quest;
    });
    if (!boards.updating) {
      history.derivedChanged.removeListener(_fold);
      _pendingText?.cancel();
    }
  }

  /// This run's quest chip; null when it did nothing for the quest. Never
  /// throws: no chip is better than no result screen.
  Future<QuestChip?> _questChip(RunStore history) async {
    try {
      if (!mounted) return null;
      final quests = AppServices.of(context).quests;
      final state = await quests.load();
      return questChipFor(
        state,
        quests.inputsFor(await history.list()),
        widget.runId,
      );
    } catch (_) {
      return null;
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
    final quest = _quest;
    if (shown.isEmpty && quest == null) return const SizedBox.shrink();
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
        if (quest != null) ...[
          if (shown.isNotEmpty) const SizedBox(height: Space.x8),
          RankChip(
            key: ValueKey('chip-quest-${quest.done}'),
            label: quest.label,
            pb: quest.done,
            celebrate: false,
            haptics: settings.haptics,
          ),
        ],
        const SizedBox(height: Space.x4),
      ],
    );
  }
}
