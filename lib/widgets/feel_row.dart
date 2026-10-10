import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/services.dart';
import '../state/companion.dart';
import '../theme/theme.dart';

/// After a run: how did it feel? Easy, Right or Hard, one tap, 56 dp targets.
/// Saved with the run on the phone first (so it works offline); sent to the
/// companion only when that is on. Shown whether or not the companion is on:
/// it is useful data either way.
class FeelRow extends StatefulWidget {
  const FeelRow({super.key, required this.runId, this.initial});
  final String runId;
  final engine.RunFeel? initial;

  @override
  State<FeelRow> createState() => _FeelRowState();
}

class _FeelRowState extends State<FeelRow> {
  late engine.RunFeel? _feel = widget.initial;

  static const Map<engine.RunFeel, String> _labels = {
    engine.RunFeel.easy: 'Easy',
    engine.RunFeel.right: 'Right',
    engine.RunFeel.hard: 'Hard',
  };

  Future<void> _tap(engine.RunFeel f) async {
    final services = AppServices.of(context);
    setState(() => _feel = f);
    await recordFeel(services.history, services.companion, widget.runId, f);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Column(
      key: const ValueKey('feel-row'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'HOW DID IT FEEL?',
          style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
        ),
        const SizedBox(height: Space.x8),
        Row(
          children: [
            for (final f in engine.RunFeel.values) ...[
              Expanded(
                child: Semantics(
                  button: true,
                  selected: _feel == f,
                  child: InkWell(
                    key: ValueKey('feel-${f.name}'),
                    onTap: () => _tap(f),
                    borderRadius: BorderRadius.circular(Radii.button),
                    child: Container(
                      height: 56,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: _feel == f ? t.inkPrimary : t.bgRaised,
                        borderRadius: BorderRadius.circular(Radii.button),
                        border: Border.all(
                          color: _feel == f ? t.inkPrimary : t.lineHair,
                          width: 2,
                        ),
                      ),
                      child: Text(
                        _labels[f]!,
                        style: RunSoloType.body17.copyWith(
                          fontWeight: FontWeight.w700,
                          color: _feel == f ? t.bgBase : t.inkPrimary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (f != engine.RunFeel.values.last)
                const SizedBox(width: Space.x12),
            ],
          ],
        ),
      ],
    );
  }
}
