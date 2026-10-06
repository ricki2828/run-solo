import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../app/services.dart';
import '../platform/gateway.dart' show Units;
import '../state/intervals_icu.dart';
import '../state/watch_guide.dart';
import '../theme/theme.dart';
import '../widgets/chrome.dart';
import '../widgets/value_stepper.dart';

/// "Send to watch" for a structured session. This is also the hook for the
/// 4-week plan: build a [engine.FitWorkout] with `FitWorkout.fromSession`
/// (pass `workPace` for a True Pace window) and open this sheet.
Future<void> showWatchWorkoutSheet(
  BuildContext context, {
  required engine.FitWorkout workout,
  int? maxHr,
}) => _show(context, WatchSheet.workout(workout: workout, maxHr: maxHr));

/// "Send to watch" for a route: a past run's route or a saved route.
Future<void> showWatchRouteSheet(
  BuildContext context, {
  required engine.SavedRoute route,
}) => _show(context, WatchSheet.route(route: route));

Future<void> _show(BuildContext context, Widget sheet) {
  final t = Theme.of(context).extension<RunSoloTokens>()!;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: t.bgBase,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
    ),
    builder: (_) => sheet,
  );
}

class WatchSheet extends StatefulWidget {
  const WatchSheet.workout({
    super.key,
    required engine.FitWorkout this.workout,
    this.maxHr,
  }) : route = null;
  const WatchSheet.route({super.key, required engine.SavedRoute this.route})
    : workout = null,
      maxHr = null;

  final engine.FitWorkout? workout;

  /// Turns a heart rate window into a percent of max HR for Intervals.icu.
  final int? maxHr;
  final engine.SavedRoute? route;

  @override
  State<WatchSheet> createState() => _WatchSheetState();
}

class _WatchSheetState extends State<WatchSheet> {
  bool _busy = false;
  String? _error;
  String? _added;

  /// Lengths for an open warm-up and cool-down on the Intervals.icu push
  /// (it needs a length for every step). The .fit keeps them open.
  int _warmMin = 10;
  int _coolMin = 5;

  bool _hasOpen(engine.FitIntensity kind) =>
      widget.workout?.steps.any(
        (s) => s.duration == engine.FitDuration.open && s.intensity == kind,
      ) ??
      false;

  String? _intervalsText() => widget.workout == null
      ? null
      : engine.IntervalsWorkoutText.fromWorkout(
          widget.workout!,
          maxHr: widget.maxHr,
          openWarmupSeconds: _warmMin * 60,
          openCooldownSeconds: _coolMin * 60,
        );

  IntervalsIcuTarget? _intervals() =>
      AppServices.of(context).sender.targets
          .whereType<IntervalsIcuTarget>()
          .firstOrNull;

  /// Put the workout on the Intervals.icu calendar for [day].
  Future<void> _push(DateTime day) async {
    final target = _intervals();
    final w = widget.workout;
    final text = _intervalsText();
    if (target == null || w == null || text == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _added = null;
    });
    String two(int v) => v.toString().padLeft(2, '0');
    final date = '${day.year}-${two(day.month)}-${two(day.day)}';
    final slug = w.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    final error = await target.pushWorkout(
      name: w.name,
      description: text,
      dateLocal: day,
      externalId: 'runsupreme-$slug-$date',
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
      _added = error == null ? Fmt.dayDate(day) : null;
    });
  }

  Future<void> _share() async {
    final exporter = AppServices.of(context).watch;
    setState(() {
      _busy = true;
      _error = null;
    });
    final w = widget.workout;
    final error = w != null
        ? await exporter.shareWorkout(w)
        : await exporter.shareRoute(widget.route!);
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _busy = false;
        _error = error;
      });
      return;
    }
    Navigator.of(context).pop();
  }

  /// "Hard reps: heart rate 162 to 181 bpm" (or a pace window), from the
  /// first step that carries a target; null when none does.
  String? _targetLine(Units units) {
    final w = widget.workout;
    if (w == null) return null;
    for (final s in w.steps) {
      final lo = s.target.low, hi = s.target.high;
      if (s.target.isOpen || lo == null || hi == null) continue;
      if (s.target.typeCode == 1) {
        return 'Hard reps: heart rate ${lo - 100} to ${hi - 100} bpm.';
      }
      // Speed in mm/s: the low edge is the slow pace.
      final slow = Fmt.pace(1000000 / lo, units);
      final fast = Fmt.pace(1000000 / hi, units);
      return 'Hard reps: pace $fast to $slow per '
          '${units == Units.mi ? 'mi' : 'km'}.';
    }
    return null;
  }

  List<Widget> _intervalsBlock(RunSoloTokens t, engine.FitWorkout w) {
    final target = _intervals();
    final text = _intervalsText();
    final now = AppServices.of(context).now();
    final today = DateTime(now.year, now.month, now.day);
    final canPush = target != null && target.connected && text != null;
    Widget button(String key, String label, DateTime day) => OutlinedButton(
      key: ValueKey(key),
      onPressed: _busy || !canPush ? null : () => _push(day),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        foregroundColor: t.inkPrimary,
        side: BorderSide(color: t.lineHair),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.button),
        ),
      ),
      child: Text(label, style: RunSoloType.body15),
    );
    return [
      const SizedBox(height: Space.x16),
      Text(
        'BEST: VIA INTERVALS.ICU',
        style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
      ),
      const SizedBox(height: Space.x8),
      Text(
        'Adds it to your Intervals.icu calendar.',
        key: const ValueKey('watch-intervals-blurb'),
        style: RunSoloType.body15.copyWith(color: t.inkSecondary),
      ),
      if (_hasOpen(engine.FitIntensity.warmup))
        ValueStepper(
          label: 'Warm-up',
          value: _warmMin == 0 ? 'None' : '$_warmMin min',
          onMinus: _warmMin > 0 ? () => setState(() => _warmMin -= 5) : null,
          onPlus: _warmMin < 30 ? () => setState(() => _warmMin += 5) : null,
        ),
      if (_hasOpen(engine.FitIntensity.cooldown))
        ValueStepper(
          label: 'Cool-down',
          value: _coolMin == 0 ? 'None' : '$_coolMin min',
          onMinus: _coolMin > 0 ? () => setState(() => _coolMin -= 5) : null,
          onPlus: _coolMin < 30 ? () => setState(() => _coolMin += 5) : null,
        ),
      const SizedBox(height: Space.x12),
      if (text == null)
        Text(
          'This session has a step Intervals.icu cannot hold. Use the file.',
          key: const ValueKey('watch-intervals-na'),
          style: RunSoloType.label13.copyWith(color: t.inkMuted),
        )
      else if (target == null || !target.connected)
        Text(
          'Connect Intervals.icu in Settings, under Send runs to',
          key: const ValueKey('watch-intervals-connect'),
          style: RunSoloType.label13.copyWith(color: t.inkMuted),
        )
      else
        Wrap(
          spacing: Space.x12,
          runSpacing: Space.x8,
          children: [
            button('watch-intervals-today', 'Add for today', today),
            button(
              'watch-intervals-tomorrow',
              'Add for tomorrow',
              today.add(const Duration(days: 1)),
            ),
          ],
        ),
      if (_added != null) ...[
        const SizedBox(height: Space.x8),
        Text(
          'Added to your Intervals.icu calendar for $_added.',
          key: const ValueKey('watch-intervals-added'),
          style: RunSoloType.label13.copyWith(color: t.inkSecondary),
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final units = AppServices.of(context).settings.settings.units;
    final workout = widget.workout;
    final isWorkout = workout != null;
    final name = isWorkout ? workout.name : widget.route!.name;
    final target = _targetLine(units);
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Space.screenGutter,
          Space.x4,
          Space.screenGutter,
          Space.x24,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const RunSheetHeader(title: 'SEND TO WATCH'),
            const SizedBox(height: Space.x8),
            Text(
              name,
              key: const ValueKey('watch-name'),
              style: RunSoloType.body17.copyWith(color: t.inkPrimary),
            ),
            const SizedBox(height: Space.x4),
            Text(
              isWorkout
                  ? 'Warm-up, reps, recoveries and cool-down.'
                  : 'A GPX course for your watch, start to end.',
              style: RunSoloType.body15.copyWith(color: t.inkSecondary),
            ),
            if (target != null) ...[
              const SizedBox(height: Space.x8),
              Text(
                target,
                key: const ValueKey('watch-target'),
                style: RunSoloType.label13.copyWith(color: t.inkSecondary),
              ),
            ],
            if (isWorkout) ..._intervalsBlock(t, workout),
            const SizedBox(height: Space.x16),
            if (isWorkout)
              Text(
                'OR SHARE A FILE',
                style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
              ),
            if (isWorkout) const SizedBox(height: Space.x8),
            OutlinedButton(
              key: const ValueKey('watch-share'),
              onPressed: _busy ? null : _share,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 48),
                foregroundColor: t.inkPrimary,
                side: BorderSide(color: t.lineHair),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Radii.button),
                ),
              ),
              child: Text(
                isWorkout ? 'Share workout file' : 'Share course file',
                style: RunSoloType.body15,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: Space.x12),
              Text(
                _error!,
                key: const ValueKey('watch-error'),
                style: RunSoloType.body15.copyWith(color: t.semWarn),
              ),
            ],
            const SizedBox(height: Space.x16),
            _HowItWorks(
              children: [
                if (isWorkout) ...[
                  Text(
                    'Intervals.icu sends the session to the watch you linked '
                    'there, up to a week ahead. It needs a length for every '
                    'step, so an open warm-up and cool-down become the timed '
                    'ones set above. Heart rate ranges come from your max '
                    'heart rate.',
                    key: const ValueKey('watch-how-intervals'),
                    style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                  ),
                  const SizedBox(height: Space.x16),
                ],
                Text(
                  'WHAT WORKS ON YOUR WATCH',
                  style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
                ),
                for (final e in WatchGuide.entries)
                  _Brand(
                    entry: e,
                    lines: isWorkout
                        ? [
                            'Via Intervals.icu: ${e.intervals}',
                            'File: ${e.workout}',
                          ]
                        : [e.route],
                    works:
                        !isWorkout ||
                        e.workoutWorks ||
                        !e.intervals.startsWith('Not'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The explanations, closed until asked for.
class _HowItWorks extends StatefulWidget {
  const _HowItWorks({required this.children});
  final List<Widget> children;

  @override
  State<_HowItWorks> createState() => _HowItWorksState();
}

class _HowItWorksState extends State<_HowItWorks> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          label: _open ? 'Hide how it works' : 'Show how it works',
          child: InkWell(
            key: const ValueKey('watch-how-toggle'),
            onTap: () => setState(() => _open = !_open),
            child: SizedBox(
              height: 56,
              child: Row(
                children: [
                  Text(
                    'HOW IT WORKS',
                    style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
                  ),
                  const Spacer(),
                  Icon(
                    _open ? Icons.expand_less : Icons.expand_more,
                    color: t.inkSecondary,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_open) ...widget.children,
      ],
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({required this.entry, required this.lines, required this.works});
  final WatchGuideEntry entry;
  final List<String> lines;
  final bool works;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Container(
      key: ValueKey('watch-${entry.brand.name}'),
      margin: const EdgeInsets.only(top: Space.x8),
      padding: const EdgeInsets.only(top: Space.x12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.lineHair)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            entry.label,
            style: RunSoloType.body17.copyWith(
              color: works ? t.inkPrimary : t.inkMuted,
            ),
          ),
          const SizedBox(height: Space.x4),
          for (final line in lines) ...[
            Text(
              line,
              style: RunSoloType.label13.copyWith(
                color: works ? t.inkSecondary : t.inkMuted,
              ),
            ),
            const SizedBox(height: Space.x4),
          ],
        ],
      ),
    );
  }
}
