import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../theme/theme.dart';

/// The load notice on Start, squeezed to one 48 dp line so it never pushes
/// the format grid below the fold: "Load is up this week · Why?". The full
/// message and the dismiss stay on Home ([LoadWarning]); Why? shows the
/// message and the rules.
class StartLoadLine extends StatelessWidget {
  const StartLoadLine({super.key, required this.flag});
  final engine.LoadFlag flag;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Semantics(
      button: true,
      label: 'Load is up this week. Why?',
      excludeSemantics: true,
      child: InkWell(
        key: const ValueKey('load-warning'),
        borderRadius: BorderRadius.circular(Radii.card),
        onTap: () => showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Why this warning?'),
            content: Text('${flag.message}\n\n${engine.LoadGuard.rules}'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Got it'),
              ),
            ],
          ),
        ),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: Space.x12),
          decoration: BoxDecoration(
            color: t.bgRaised,
            borderRadius: BorderRadius.circular(Radii.card),
            border: Border.all(color: t.semWarn),
          ),
          child: Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 20, color: t.semWarn),
              const SizedBox(width: Space.x8),
              Expanded(
                child: Text(
                  'Load is up this week · Why?',
                  key: const ValueKey('load-message'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: RunSoloType.body15.copyWith(color: t.inkPrimary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
