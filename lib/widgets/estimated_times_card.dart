import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../theme/theme.dart';

/// Home ESTIMATED TIMES (design A10.4, PD2): one row per distance, the
/// source line, the empty or stale line. Tap expands a band line under each
/// row (240 ms; reduced motion: cut); tap again collapses. Bone numbers,
/// never Arc; no trend. Every string is the engine's.
class EstimatedTimesCard extends StatefulWidget {
  const EstimatedTimesCard({super.key, required this.estimates});

  final engine.HomeEstimates estimates;

  @override
  State<EstimatedTimesCard> createState() => _EstimatedTimesCardState();
}

class _EstimatedTimesCardState extends State<EstimatedTimesCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final e = widget.estimates;
    final reduced = MediaQuery.disableAnimationsOf(context);
    final header = Text(
      engine.HomeEstimates.title,
      style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
    );
    if (e.message != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          const SizedBox(height: Space.x8),
          Text(
            e.message!,
            style: RunSoloType.body15.copyWith(color: t.inkSecondary),
          ),
        ],
      );
    }
    return Semantics(
      button: true,
      toggled: _open,
      child: InkWell(
        onTap: () => setState(() => _open = !_open),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            header,
            const SizedBox(height: Space.x8),
            for (final r in e.rows) ...[
              Semantics(
                container: true,
                label: r.semantics,
                excludeSemantics: true,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Expanded(
                      child: Text(
                        r.label,
                        style: RunSoloType.body17.copyWith(color: t.inkPrimary),
                      ),
                    ),
                    Text(
                      r.time,
                      style: RunSoloType.display44.copyWith(
                        color: t.inkPrimary,
                        fontFeatures: RunSoloType.tabular,
                      ),
                    ),
                  ],
                ),
              ),
              AnimatedSize(
                duration: reduced
                    ? Duration.zero
                    : const Duration(milliseconds: 240),
                alignment: Alignment.topLeft,
                child: _open && r.band != null
                    ? Padding(
                        padding: const EdgeInsets.only(bottom: Space.x8),
                        child: Text(
                          r.band!,
                          style: RunSoloType.body15.copyWith(
                            color: t.inkSecondary,
                          ),
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ],
            const SizedBox(height: Space.x4),
            for (final s in e.sourceLines)
              Text(
                s,
                style: RunSoloType.label13.copyWith(color: t.inkSecondary),
              ),
          ],
        ),
      ),
    );
  }
}
