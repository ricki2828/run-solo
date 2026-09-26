import 'package:flutter/material.dart';

import '../app/event_names.dart';
import '../app/services.dart';
import '../state/boards.dart';
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
  late final Future<Boards> _boards = AppServices.of(context).history.boards();

  @override
  Widget build(BuildContext context) {
    final services = AppServices.of(context);
    final settings = services.settings.settings;
    return FutureBuilder<Boards>(
      future: _boards,
      builder: (context, snap) {
        final chips = snap.data?.chipsFor(
          widget.runId,
          units: settings.units,
          names: kEventNames,
        );
        if (chips == null || chips.isEmpty) return const SizedBox.shrink();
        return Column(
          key: const ValueKey('board-chips'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final c in chips)
              RankChip(
                label: c.label,
                pb: c.pb,
                celebrate: widget.justFinished && c == chips.first,
                haptics: settings.haptics,
                onTap: widget.onTapBoard == null
                    ? null
                    : () => widget.onTapBoard!(c.boardKey),
              ),
            const SizedBox(height: Space.x4),
          ],
        );
      },
    );
  }
}
