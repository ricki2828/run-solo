import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/services.dart';
import '../state/load_guard.dart';
import '../theme/theme.dart';

/// The "don't overdo it" notice: one plain line, why it is showing, and a
/// dismiss for the rest of the week. Never blocks anything.
class LoadWarning extends StatelessWidget {
  const LoadWarning({super.key, required this.flag, required this.now});
  final engine.LoadFlag flag;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Container(
      key: const ValueKey('load-warning'),
      padding: const EdgeInsets.all(Space.x12),
      decoration: BoxDecoration(
        color: t.bgRaised,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(color: t.semWarn),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded, size: 20, color: t.semWarn),
              const SizedBox(width: Space.x8),
              Expanded(
                child: Text(
                  flag.message,
                  key: const ValueKey('load-message'),
                  style: RunSoloType.body15.copyWith(color: t.inkPrimary),
                ),
              ),
            ],
          ),
          Row(
            children: [
              TextButton(
                key: const ValueKey('load-why'),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Why this warning?'),
                    content: Text(engine.LoadGuard.rules),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('Got it'),
                      ),
                    ],
                  ),
                ),
                child: const Text('Why?'),
              ),
              TextButton(
                key: const ValueKey('load-dismiss'),
                onPressed: () =>
                    AppServices.of(context).settings
                        .update(LoadDismissal.dismiss(now)),
                child: const Text('Dismiss for this week'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
