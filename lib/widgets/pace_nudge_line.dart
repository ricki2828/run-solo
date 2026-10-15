import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../app/services.dart';
import '../state/history_store.dart';
import '../state/target_pace.dart';
import '../theme/theme.dart';

final ButtonStyle _tap = TextButton.styleFrom(minimumSize: const Size(48, 48));

/// "Your easy pace looks quicker now: 5:20 to 5:10?" with Yes and Keep.
/// Shows only when the engine finds sustained evidence; a target never
/// changes until Yes is tapped. Nothing at all otherwise.
class PaceNudgeLine extends StatefulWidget {
  const PaceNudgeLine({super.key, required this.runs, required this.now});

  final List<RunSummary> runs;
  final DateTime now;

  @override
  State<PaceNudgeLine> createState() => _PaceNudgeLineState();
}

class _PaceNudgeLineState extends State<PaceNudgeLine> {
  bool _prepared = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final live = AppServices.of(context).live;
    if (_prepared || live == null) return;
    _prepared = true;
    live.prepare().then((_) {
      if (mounted) setState(() {});
    }, onError: (Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    final services = AppServices.of(context);
    final controller = services.targetPaces;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        engine.PaceNudge? nudge;
        try {
          final paces = services.live?.targetPaces(adopted: controller.adopted);
          if (paces != null) {
            nudge = controller.nudge(
              paces,
              paceEvidence(widget.runs, zones: services.hrZones),
              now: widget.now,
            );
          }
        } catch (_) {
          nudge = null;
        }
        if (nudge == null) return const SizedBox.shrink();
        return _Line(nudge: nudge, controller: controller, now: widget.now);
      },
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({
    required this.nudge,
    required this.controller,
    required this.now,
  });

  final engine.PaceNudge nudge;
  final TargetPaceController controller;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final units = AppServices.of(context).settings.settings.units;
    return Padding(
      key: const ValueKey('pace-nudge'),
      padding: const EdgeInsets.only(bottom: Space.x8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            nudge.line(engine.Units.values.byName(units.name)),
            key: const ValueKey('pace-nudge-text'),
            style: RunSoloType.body15.copyWith(color: t.inkPrimary),
          ),
          Wrap(
            children: [
              TextButton(
                key: const ValueKey('pace-nudge-yes'),
                style: _tap,
                onPressed: () {
                  controller.accept(nudge, now: now);
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    SnackBar(
                      content: Text(
                        '${nudge.intensity.label} pace is now '
                        '${Fmt.paceUnit(nudge.toSecPerKm, units)}.',
                      ),
                      action: SnackBarAction(
                        label: 'Undo',
                        onPressed: () => controller.reset(nudge.intensity),
                      ),
                    ),
                  );
                },
                child: Text('Yes, ${Fmt.paceUnit(nudge.toSecPerKm, units)}'),
              ),
              TextButton(
                key: const ValueKey('pace-nudge-keep'),
                style: _tap,
                onPressed: () => controller.keep(nudge, now: now),
                child: Text('Keep ${Fmt.paceUnit(nudge.fromSecPerKm, units)}'),
              ),
              TextButton(
                key: const ValueKey('pace-nudge-why'),
                style: _tap,
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Why this change?'),
                    content: Text(
                      '${nudge.why}\n\n'
                      '${engine.TargetPaces.methods[nudge.intensity]}.\n\n'
                      'Nothing changes unless you tap Yes.',
                    ),
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
            ],
          ),
        ],
      ),
    );
  }
}
