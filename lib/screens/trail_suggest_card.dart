import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/services.dart';
import '../platform/gateway.dart';
import '../state/history_store.dart';
import '../theme/theme.dart';

/// Whether the result screen offers to save this run as Trail: a Free run
/// whose climb looks like a trail's. The rule itself lives in the engine
/// ([engine.TrailSuggestion]) so it can move to barometer gain in one place.
bool trailSuggested(engine.RunFile run, RecordMode mode) =>
    mode == RecordMode.free &&
    engine.TrailSuggestion.suggests(run, mode: runModeOf(mode));

/// "Looks like a trail run. Save it as Trail?" Yes re-tags the run (a run-type
/// override on its sidecar), which recomputes its title, colour, index row and
/// verdict; Not now hides the card for this visit and changes nothing.
class TrailSuggestCard extends StatefulWidget {
  const TrailSuggestCard({
    super.key,
    required this.runId,
    required this.onSaved,
  });
  final String runId;

  /// The run was re-tagged: the caller reloads it under its new type.
  final VoidCallback onSaved;

  @override
  State<TrailSuggestCard> createState() => _TrailSuggestCardState();
}

class _TrailSuggestCardState extends State<TrailSuggestCard> {
  bool _hidden = false;
  bool _busy = false;
  bool _failed = false;

  Future<void> _yes() async {
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      await AppServices.of(context).history
          .setOverride(widget.runId, RecordMode.trail);
    } catch (e) {
      debugPrint('trail re-tag failed ($e)');
      if (mounted) {
        setState(() {
          _busy = false;
          _failed = true;
        });
      }
      return;
    }
    if (mounted) widget.onSaved();
  }

  @override
  Widget build(BuildContext context) {
    if (_hidden) return const SizedBox.shrink();
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Container(
      key: const ValueKey('trail-suggest'),
      width: double.infinity,
      padding: const EdgeInsets.all(Space.cardPadding),
      decoration: BoxDecoration(
        color: t.bgRaised,
        borderRadius: BorderRadius.circular(Radii.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              children: [
                const TextSpan(text: 'Looks like a trail run. Save it as '),
                TextSpan(
                  text: 'Trail',
                  style: TextStyle(color: AuroraRunType.trail),
                ),
                const TextSpan(text: '?'),
              ],
            ),
            style: RunSoloType.heading19.copyWith(color: t.inkPrimary),
          ),
          if (_failed) ...[
            const SizedBox(height: Space.x4),
            Text(
              'Could not save that. Try again.',
              style: RunSoloType.label13.copyWith(color: t.semWarn),
            ),
          ],
          const SizedBox(height: Space.x12),
          Row(
            children: [
              // The theme's buttons are full width: share the row.
              Expanded(
                child: FilledButton(
                  key: const ValueKey('trail-suggest-yes'),
                  onPressed: _busy ? null : _yes,
                  child: const Text('YES'),
                ),
              ),
              const SizedBox(width: Space.x12),
              Expanded(
                child: TextButton(
                  key: const ValueKey('trail-suggest-no'),
                  onPressed: _busy
                      ? null
                      : () => setState(() => _hidden = true),
                  child: const Text('NOT NOW'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
