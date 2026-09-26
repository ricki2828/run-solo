import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../state/sessions.dart';
import '../theme/theme.dart';
import '../widgets/structure_glyph.dart';
import '../widgets/value_stepper.dart';
import 'intervals_sheet.dart';

/// What the builder hands back: the template to save, and whether to start.
typedef BuilderResult = ({CustomSession session, bool start});

/// Custom builder (plan §3.4, design brief A8): Reps · Rep (Time |
/// Distance) · Recovery (Time | Distance | None, Jog / Walk / Stand) ·
/// Warm-up (Open | Fixed) · Cool-down (Open | Fixed), with a live glyph and
/// total on top. SAVE and SAVE & START. The caller stores the result.
class CustomBuilderScreen extends StatefulWidget {
  const CustomBuilderScreen({super.key, required this.initial});

  /// A new template (fresh id) or one pre-filled by "Save as custom".
  final CustomSession initial;

  @override
  State<CustomBuilderScreen> createState() => _CustomBuilderScreenState();
}

class _CustomBuilderScreenState extends State<CustomBuilderScreen> {
  late CustomSession _s = widget.initial;

  /// The name follows the structure until the runner types their own.
  late bool _autoName =
      widget.initial.name.isEmpty ||
      widget.initial.name == widget.initial.autoName;

  void _set(CustomSession Function(CustomSession) f) => setState(() {
    var next = f(_s);
    if (_autoName) next = next.copyWith(name: next.autoName);
    _s = next;
  });

  @override
  void initState() {
    super.initState();
    if (_autoName) _s = _s.copyWith(name: _s.autoName);
  }

  static int _stepTime(int v, int dir, (int, int) range) =>
      (v + dir * SessionRules.timeStep).clamp(range.$1, range.$2);

  static int _stepDistance(int v, int dir, (int, int) range) {
    final step = SessionRules.distanceStepAt(v, up: dir > 0);
    return (v + dir * step).clamp(range.$1, range.$2);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final spec = _s.expand();
    final problems = _s.validate();
    final timeWork = _s.workTarget == engine.TargetKind.time;
    final timedOnly =
        _s.recoveryStyle == engine.RecoveryStyle.walk ||
        _s.recoveryStyle == engine.RecoveryStyle.stand;
    final workRange = timeWork
        ? SessionRules.workTime
        : SessionRules.workDistance;
    final recRange = _s.recoveryTarget == RecoveryTarget.distance
        ? SessionRules.recoveryDistance
        : SessionRules.recoveryTime;

    String value(bool time, int v) =>
        time ? SessionText.clock(v) : SessionText.metres(v);

    return Scaffold(
      appBar: AppBar(
        title: const Text('CUSTOM'),
        leading: IconButton(
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: Space.screenGutter),
          children: [
            const SizedBox(height: Space.x8),
            // Live preview: glyph, name, structure and the estimate.
            Container(
              padding: const EdgeInsets.all(Space.x12),
              decoration: BoxDecoration(
                color: t.bgSunken,
                borderRadius: BorderRadius.circular(Radii.card),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  StructureGlyph(spec: spec, height: 32),
                  const SizedBox(height: Space.x8),
                  InkWell(
                    key: const ValueKey('builder-name'),
                    onTap: () async {
                      final n = await askSessionName(context, _s.name);
                      if (n == null || n.isEmpty) return;
                      setState(() {
                        _autoName = n == _s.autoName;
                        _s = _s.copyWith(name: n);
                      });
                    },
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            _s.name.toUpperCase(),
                            maxLines: 2,
                            style: RunSoloType.title28.copyWith(
                              color: t.inkPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: Space.x8),
                        Icon(Icons.edit, size: 18, color: t.inkSecondary),
                      ],
                    ),
                  ),
                  Text(
                    'total ~${SessionText.estimateMinutes(spec)} min',
                    style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Space.x8),
            ValueStepper(
              label: 'Reps',
              value: '${_s.reps}',
              onMinus: _s.reps > SessionRules.minReps
                  ? () => _set((x) => x.copyWith(reps: x.reps - 1))
                  : null,
              onPlus: _s.reps < SessionRules.maxReps
                  ? () => _set((x) => x.copyWith(reps: x.reps + 1))
                  : null,
            ),
            _Segmented<engine.TargetKind>(
              key: const ValueKey('builder-work-target'),
              label: 'Each rep',
              value: _s.workTarget,
              options: const [
                (engine.TargetKind.time, 'Time'),
                (engine.TargetKind.distance, 'Distance'),
              ],
              onChanged: (v) => _set(
                (x) => x.copyWith(
                  workTarget: v,
                  workValue: v == engine.TargetKind.time ? 180 : 400,
                ),
              ),
            ),
            ValueStepper(
              label: 'Rep',
              value: value(timeWork, _s.workValue),
              onMinus: _s.workValue > workRange.$1
                  ? () => _set(
                      (x) => x.copyWith(
                        workValue: timeWork
                            ? _stepTime(x.workValue, -1, workRange)
                            : _stepDistance(x.workValue, -1, workRange),
                      ),
                    )
                  : null,
              onPlus: _s.workValue < workRange.$2
                  ? () => _set(
                      (x) => x.copyWith(
                        workValue: timeWork
                            ? _stepTime(x.workValue, 1, workRange)
                            : _stepDistance(x.workValue, 1, workRange),
                      ),
                    )
                  : null,
            ),
            _Segmented<RecoveryTarget>(
              key: const ValueKey('builder-recovery-target'),
              label: 'Recovery',
              value: _s.recoveryTarget,
              options: const [
                (RecoveryTarget.time, 'Time'),
                (RecoveryTarget.distance, 'Distance'),
                (RecoveryTarget.none, 'None'),
              ],
              disabled: timedOnly ? const {RecoveryTarget.distance} : const {},
              onChanged: (v) => _set(
                (x) => x.copyWith(
                  recoveryTarget: v,
                  recoveryValue: switch (v) {
                    RecoveryTarget.time => 120,
                    RecoveryTarget.distance => 200,
                    RecoveryTarget.none => 0,
                  },
                ),
              ),
            ),
            if (_s.recoveryTarget != RecoveryTarget.none) ...[
              ValueStepper(
                label: 'Recovery',
                value: value(
                  _s.recoveryTarget == RecoveryTarget.time,
                  _s.recoveryValue,
                ),
                onMinus: _s.recoveryValue > recRange.$1
                    ? () => _set(
                        (x) => x.copyWith(
                          recoveryValue: x.recoveryTarget == RecoveryTarget.time
                              ? _stepTime(x.recoveryValue, -1, recRange)
                              : _stepDistance(x.recoveryValue, -1, recRange),
                        ),
                      )
                    : null,
                onPlus: _s.recoveryValue < recRange.$2
                    ? () => _set(
                        (x) => x.copyWith(
                          recoveryValue: x.recoveryTarget == RecoveryTarget.time
                              ? _stepTime(x.recoveryValue, 1, recRange)
                              : _stepDistance(x.recoveryValue, 1, recRange),
                        ),
                      )
                    : null,
              ),
              _Segmented<engine.RecoveryStyle>(
                key: const ValueKey('builder-style'),
                label: 'Recovery style',
                value: _s.recoveryStyle,
                options: const [
                  (engine.RecoveryStyle.jog, 'Jog'),
                  (engine.RecoveryStyle.walk, 'Walk'),
                  (engine.RecoveryStyle.stand, 'Stand'),
                ],
                onChanged: (v) => _set((x) {
                  final timed =
                      v == engine.RecoveryStyle.walk ||
                      v == engine.RecoveryStyle.stand;
                  return timed && x.recoveryTarget == RecoveryTarget.distance
                      ? x.copyWith(
                          recoveryStyle: v,
                          recoveryTarget: RecoveryTarget.time,
                          recoveryValue: 120,
                        )
                      : x.copyWith(recoveryStyle: v);
                }),
              ),
              if (timedOnly)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.x8),
                  child: Text(
                    'Walk and stand recoveries are timed.',
                    style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                  ),
                ),
            ],
            _OpenOrFixed(
              key: const ValueKey('builder-warmup'),
              label: 'Warm-up',
              seconds: _s.warmupSeconds,
              openNote: 'Open: tap START REPS when ready.',
              onChanged: (v) => _set(
                (x) => v == null
                    ? x.copyWith(openWarmup: true)
                    : x.copyWith(warmupSeconds: v),
              ),
            ),
            _OpenOrFixed(
              key: const ValueKey('builder-cooldown'),
              label: 'Cool-down',
              seconds: _s.cooldownSeconds,
              openNote: 'Open: tap Stop when done.',
              onChanged: (v) => _set(
                (x) => v == null
                    ? x.copyWith(openCooldown: true)
                    : x.copyWith(cooldownSeconds: v),
              ),
            ),
            if (problems.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: Space.x8),
                child: Text(
                  problems.first,
                  key: const ValueKey('builder-problem'),
                  style: RunSoloType.label13.copyWith(color: t.semDanger),
                ),
              ),
            const SizedBox(height: Space.x24),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Space.screenGutter,
            Space.x12,
            Space.screenGutter,
            Space.x24,
          ),
          child: Row(
            children: [
              Expanded(
                flex: 2,
                child: OutlinedButton(
                  key: const ValueKey('builder-save'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(64),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(Radii.button),
                    ),
                    side: BorderSide(color: t.inkPrimary),
                    foregroundColor: t.inkPrimary,
                  ),
                  onPressed: problems.isEmpty
                      ? () =>
                            Navigator.of(context)
                                .pop<BuilderResult>((session: _s, start: false))
                      : null,
                  child: const Text('SAVE'),
                ),
              ),
              const SizedBox(width: Space.x12),
              Expanded(
                flex: 4,
                child: FilledButton(
                  key: const ValueKey('builder-save-start'),
                  onPressed: problems.isEmpty
                      ? () =>
                            Navigator.of(context)
                                .pop<BuilderResult>((session: _s, start: true))
                      : null,
                  child: const Text('SAVE & START'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Label over a row of 48 dp choices; selected = Bone fill.
class _Segmented<T> extends StatelessWidget {
  const _Segmented({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.disabled = const {},
  });
  final String label;
  final T value;
  final List<(T, String)> options;
  final Set<T> disabled;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Padding(
      padding: const EdgeInsets.only(top: Space.x12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
          ),
          const SizedBox(height: Space.x8),
          Row(
            children: [
              for (final (v, text) in options) ...[
                if (v != options.first.$1) const SizedBox(width: Space.x8),
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: v == value,
                    enabled: !disabled.contains(v),
                    child: InkWell(
                      key: ValueKey('seg-$label-$text'),
                      borderRadius: BorderRadius.circular(Radii.chip),
                      onTap: disabled.contains(v) ? null : () => onChanged(v),
                      child: Container(
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: v == value ? t.inkPrimary : t.bgRaised,
                          borderRadius: BorderRadius.circular(Radii.chip),
                          border: Border.all(color: t.lineHair),
                        ),
                        child: Text(
                          text,
                          style: RunSoloType.label13.copyWith(
                            fontSize: 15,
                            color: v == value
                                ? t.bgBase
                                : disabled.contains(v)
                                ? t.inkMuted
                                : t.inkPrimary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Warm-up / cool-down: Open, or Fixed 5:00–20:00 in 1-minute steps.
class _OpenOrFixed extends StatelessWidget {
  const _OpenOrFixed({
    super.key,
    required this.label,
    required this.seconds,
    required this.openNote,
    required this.onChanged,
  });
  final String label;
  final int? seconds;
  final String openNote;

  /// null = open.
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final s = seconds;
    final (lo, hi) = SessionRules.warmup;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Segmented<bool>(
          label: label,
          value: s == null,
          options: const [(true, 'Open'), (false, 'Fixed')],
          onChanged: (open) => onChanged(open ? null : 600),
        ),
        if (s == null)
          Padding(
            padding: const EdgeInsets.only(top: Space.x8),
            child: Text(
              openNote,
              style: RunSoloType.label13.copyWith(color: t.inkSecondary),
            ),
          )
        else
          ValueStepper(
            label: label,
            value: SessionText.clock(s),
            onMinus: s > lo ? () => onChanged((s - 60).clamp(lo, hi)) : null,
            onPlus: s < hi ? () => onChanged((s + 60).clamp(lo, hi)) : null,
          ),
      ],
    );
  }
}
