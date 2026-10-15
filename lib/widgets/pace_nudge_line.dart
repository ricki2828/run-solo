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
  const PaceNudgeLine({
    super.key,
    required this.runs,
    required this.now,
    this.pacesOverride,
  });

  final List<RunSummary> runs;
  final DateTime now;

  /// Tests: targets to judge against, in place of the prepared index.
  final engine.TargetPaces? pacesOverride;

  @override
  State<PaceNudgeLine> createState() => _PaceNudgeLineState();
}

class _PaceNudgeLineState extends State<PaceNudgeLine> {
  bool _prepared = false;

  // Home rebuilds often; the fitness figure and the evidence are only
  // recomputed when their inputs move.
  Object? _pacesKey;
  engine.TargetPaces? _paces;
  List<RunSummary>? _evidenceRuns;
  int _evidenceLen = -1;
  Map<engine.PaceIntensity, List<engine.PaceObservation>> _evidence = const {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final live = AppServices.of(context).live;
    if (_prepared || live == null) return;
    _prepared = true;
    live.prepare().then((_) {
      if (mounted) {
        setState(() {
          _pacesKey = null;
          _evidenceRuns = null;
        });
      }
    }, onError: (Object _) {});
  }

  engine.PaceNudge? _find(AppServices services, TargetPaceController c) {
    try {
      final key = (c.state, widget.now.year, widget.now.month, widget.now.day);
      if (widget.pacesOverride != null) {
        _paces = widget.pacesOverride;
      } else if (_pacesKey != key) {
        _paces = services.currentTargetPaces();
        _pacesKey = key;
      }
      final paces = _paces;
      if (paces == null) return null;
      if (!identical(_evidenceRuns, widget.runs) ||
          _evidenceLen != widget.runs.length) {
        _evidence = paceEvidence(widget.runs, zones: services.hrZones);
        _evidenceRuns = widget.runs;
        _evidenceLen = widget.runs.length;
      }
      return c.nudge(paces, _evidence, now: widget.now);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = AppServices.of(context);
    final controller = services.targetPaces;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final nudge = _find(services, controller);
        if (nudge == null) return const SizedBox.shrink();
        return _Line(
          nudge: nudge,
          controller: controller,
          now: widget.now,
          modelSecPerKm: _paces?[nudge.intensity]?.modelSecPerKm,
        );
      },
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({
    required this.nudge,
    required this.controller,
    required this.now,
    this.modelSecPerKm,
  });

  final double? modelSecPerKm;
  final engine.PaceNudge nudge;
  final TargetPaceController controller;
  final DateTime now;

  void _say(BuildContext context, String text, {SnackBarAction? action}) =>
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(text), action: action));

  Future<void> _yes(BuildContext context, String paceText) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await controller.accept(nudge, now: now, modelSecPerKm: modelSecPerKm);
    } catch (_) {
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('Could not save that. The pace is unchanged.'),
        ),
      );
      return;
    }
    messenger?.showSnackBar(
      SnackBar(
        content: Text('${nudge.intensity.label} pace is now $paceText.'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            try {
              await controller.reset(nudge.intensity);
            } catch (_) {
              messenger?.showSnackBar(
                const SnackBar(content: Text('Could not undo that.')),
              );
            }
          },
        ),
      ),
    );
  }

  Future<void> _keep(BuildContext context) async {
    try {
      await controller.keep(nudge, now: now);
    } catch (_) {
      if (context.mounted) {
        _say(context, 'Could not save that. It will ask again.');
      }
    }
  }

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
                onPressed: () =>
                    _yes(context, Fmt.paceUnit(nudge.toSecPerKm, units)),
                child: Text('Yes, ${Fmt.paceUnit(nudge.toSecPerKm, units)}'),
              ),
              TextButton(
                key: const ValueKey('pace-nudge-keep'),
                style: _tap,
                onPressed: () => _keep(context),
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
