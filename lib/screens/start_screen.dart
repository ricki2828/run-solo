import 'dart:async';

import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/routes.dart';
import '../app/services.dart';
import '../platform/gateway.dart';
import '../platform/session_codec.dart';
import '../state/live_context.dart';
import '../state/recording_controller.dart';
import '../state/sessions.dart';
import '../state/settings.dart';
import '../theme/theme.dart';
import '../widgets/chrome.dart';
import '../widgets/mode_chip.dart';
import '../widgets/structure_glyph.dart';
import '../widgets/value_stepper.dart';
import 'custom_builder_screen.dart';
import 'intervals_sheet.dart';

/// Start (plan §3.2, design brief A8): INTERVALS / LAPS / FREE. Tapping
/// INTERVALS opens the sheet; the picked session shows as the session card
/// (reps and recovery steppers only, D2; anything else is Save as custom).
/// Cue toggles, strap status, START. Typed start errors map to copy here;
/// permission errors route to the checklist.
class StartScreen extends StatefulWidget {
  const StartScreen({super.key});

  @override
  State<StartScreen> createState() => _StartScreenState();
}

class _StartScreenState extends State<StartScreen> {
  bool _starting = false;
  String? _error;

  /// False on Android 14: the toggle is disabled with a reason.
  bool _volumeKeyLaps = true;
  bool _volumeKeyChecked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_volumeKeyChecked) return;
    _volumeKeyChecked = true;
    // LC1: get the live compare's candidates ready off the UI isolate, so
    // the Start press only plans over them (#59 review P2).
    if (kLiveCompare) unawaited(AppServices.of(context).live?.prepare());
    AppServices.of(context).permissions.volumeKeyLapsSupported().then((ok) {
      if (mounted && ok != _volumeKeyLaps) setState(() => _volumeKeyLaps = ok);
    });
  }

  Future<void> _start() async {
    final services = AppServices.of(context);
    final s = services.settings.settings;
    setState(() {
      _starting = true;
      _error = null;
    });
    StartResult result;
    try {
      await services.recorder.setCues(s.cues);
      await services.recorder.setKmSplits(s.kmSplits);
      if (s.recordMode == RecordMode.laps) {
        await services.recorder.setVolumeKeyLaps(
          s.volumeKeyLapFor(RecordMode.laps),
        );
      }
      // CONTRACT.md I1: the app expands the session; Kotlin runs it.
      // Fartlek is a Laps run carrying the fartlek session (plan §3.5).
      final mode = s.recordMode;
      final spec = switch (s.lastMode) {
        RecordMode.intervals => services.pickedSession.toPigeon(),
        RecordMode.cooper => engine.SessionSpec.cooper.toPigeon(),
        RecordMode.laps || RecordMode.free => null,
      };
      // LC1: the live compare's history, 150 ms or none; off until LV2.
      final live = kLiveCompare
          ? await services.live?.build(mode: mode, spec: spec)
          : null;
      result = await services.recording.start(
        mode,
        spec,
        s.units,
        liveContext: live,
      );
    } catch (e) {
      // A PlatformException must never strand the button in "starting".
      if (mounted) {
        setState(() {
          _starting = false;
          _error = 'Could not start recording. Try again.';
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() => _starting = false);
    final err = result.error;
    if (err == null || err == StartError.alreadyRunning) {
      await Navigator.of(context).pushReplacementNamed(Routes.recording);
      return;
    }
    switch (err) {
      case StartError.noFinePermission:
      case StartError.approximateOnly:
      case StartError.notificationsDenied:
        final ok = await Navigator.of(context).pushNamed(Routes.permissions);
        if (ok == true && mounted) await _start();
      case StartError.locationOff:
        setState(
          () =>
              _error = 'Location is off on this phone. Turn it on, then start.',
        );
      case StartError.lowStorage:
        setState(
          () => _error = 'Not enough storage to record. Free some space first.',
        );
      case StartError.fgsNotAllowed:
        setState(
          () => _error =
              'Android would not let recording start. Keep the app open '
              'and try again.',
        );
      case StartError.noSuchJournal:
      case StartError.replayUnavailable:
      case StartError.startFailed:
      case StartError.resumeFailed:
        setState(() => _error = 'Could not start recording. Try again.');
      case StartError.unsupportedSession:
        setState(
          () => _error = 'This version cannot run that session. Pick another.',
        );
      case StartError.alreadyRunning:
        break;
    }
  }

  /// The Intervals sheet (A8). Picking a card selects Intervals too; the
  /// back arrow changes nothing.
  Future<void> _openSheet() async {
    final services = AppServices.of(context);
    final r = await showIntervalsSheet(
      context,
      currentId: services.settings.settings.sessionId,
    );
    if (!mounted || r == null) return;
    switch (r) {
      case PickSession(:final id):
        await services.settings.update(
          (x) => x.copyWith(lastMode: RecordMode.intervals, sessionId: id),
        );
      case BuildCustom():
        await _build(null);
    }
  }

  /// Custom builder: a new template, or one pre-filled ("Save as custom").
  /// Saved templates are picked; SAVE & START starts the warm-up.
  Future<void> _build(CustomSession? initial, {bool editing = false}) async {
    final services = AppServices.of(context);
    if (services.sessions.full && !editing) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('You have 20 sessions. Delete one first.'),
        ),
      );
      return;
    }
    final r = await Navigator.of(context).push<BuilderResult>(
      MaterialPageRoute(
        builder: (_) => CustomBuilderScreen(
          initial:
              initial ?? CustomSession(id: services.sessions.newId(), name: ''),
        ),
      ),
    );
    if (!mounted || r == null) return;
    final stored = await services.sessions.save(r.session);
    await services.settings.update(
      (x) => x.copyWith(
        lastMode: RecordMode.intervals,
        sessionId: stored.templateId,
      ),
    );
    if (r.start && mounted) await _start();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final text = Theme.of(context).textTheme;
    final services = AppServices.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([services.settings, services.sessions]),
      builder: (context, _) {
        final s = services.settings.settings;
        final mode = s.lastMode;
        final preset = mode == RecordMode.intervals;
        Future<void> set(AppSettings Function(AppSettings) f) =>
            services.settings.update(f);
        return Scaffold(
          appBar: AppBar(title: const Text('START')),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.screenGutter,
              ),
              children: [
                const SizedBox(height: Space.x8),
                ModeChipRow(
                  selected: mode,
                  session: services.pickedSession,
                  onSelect: (m) => m == RecordMode.intervals
                      ? _openSheet()
                      : set((x) => x.copyWith(lastMode: m)),
                ),
                const SizedBox(height: Space.x24),
                if (preset) ...[
                  _SessionCard(
                    spec: services.pickedSession,
                    settings: s,
                    onChange: _openSheet,
                    onEdit: set,
                    // A custom template edits in place (same id); a preset
                    // becomes a new template pre-filled from its edits.
                    onSaveAsCustom: () => _build(
                      services.sessions.byTemplateId(s.sessionId) ??
                          SessionChoice.asCustom(
                            services.pickedSession,
                            services.sessions.newId(),
                          ),
                      editing:
                          services.sessions.byTemplateId(s.sessionId) != null,
                    ),
                  ),
                  const SizedBox(height: Space.x16),
                  _Toggle(
                    label: 'Voice cues',
                    value: s.cues,
                    onChanged: (v) => set((x) => x.copyWith(cues: v)),
                  ),
                  _Toggle(
                    label: 'Haptic cues',
                    value: s.haptics,
                    onChanged: (v) => set((x) => x.copyWith(haptics: v)),
                  ),
                ] else if (mode == RecordMode.laps) ...[
                  Text(
                    'Tap LAP at each interval. No timer phases, no cues; '
                    'you get a lap table, not a verdict.',
                    style: text.bodyMedium?.copyWith(color: t.inkSecondary),
                  ),
                  const SizedBox(height: Space.x16),
                  _Toggle(
                    label: 'Volume-key lap',
                    value: _volumeKeyLaps && s.volumeKeyLapFor(RecordMode.laps),
                    onChanged: _volumeKeyLaps
                        ? (v) => set((x) => x.copyWith(volumeKeyLap: v))
                        : null,
                  ),
                  if (!_volumeKeyLaps)
                    Text(
                      kVolumeKeyToggleReason,
                      style: RunSoloType.label13.copyWith(
                        color: t.inkSecondary,
                      ),
                    ),
                ] else ...[
                  Text(
                    'Free run: time, distance, pace and heart rate. No laps. '
                    'Pause and hold-to-stop as usual.',
                    style: text.bodyMedium?.copyWith(color: t.inkSecondary),
                  ),
                ],
                const SizedBox(height: Space.x16),
                Row(
                  children: [
                    Icon(Icons.favorite, size: 16, color: t.hrZone),
                    const SizedBox(width: Space.x8),
                    Text(
                      s.strap == null ? 'No strap' : 'Strap: ${s.strap!.label}',
                      style: RunSoloType.body15.copyWith(
                        color: s.strap == null ? t.inkSecondary : t.inkPrimary,
                      ),
                    ),
                    const Spacer(),
                    StatusPill(
                      label: s.units == Units.km ? 'KM' : 'MI',
                      tone: PillTone.ok,
                    ),
                  ],
                ),
                const SizedBox(height: Space.x16),
              ],
            ),
          ),
          // Pinned: the primary action stays on screen at 360 x 800 however
          // long the options above get; the options scroll behind it.
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.screenGutter,
                Space.x12,
                Space.screenGutter,
                Space.x24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Space.x12),
                      child: Text(
                        _error!,
                        style: text.labelLarge?.copyWith(color: t.semDanger),
                      ),
                    ),
                  FilledButton(
                    onPressed: _starting ? null : _start,
                    child: Text(switch (mode) {
                      RecordMode.intervals
                          when SessionChoice.isFartlek(s.sessionId) =>
                        'START FARTLEK',
                      RecordMode.intervals => 'START WARM-UP',
                      RecordMode.laps => 'START LAPS RUN',
                      RecordMode.free => 'START FREE RUN',
                      RecordMode.cooper => 'START TEST',
                    }),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.label,
    required this.value,
    required this.onChanged,
  });
  final String label;
  final bool value;

  /// Null disables the switch.
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: RunSoloType.body17.copyWith(color: t.inkPrimary),
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: t.bgBase,
            activeTrackColor: t.inkPrimary,
            inactiveThumbColor: t.inkSecondary,
            inactiveTrackColor: t.bgRaised,
          ),
        ],
      ),
    );
  }
}

/// The picked session on Start (design brief A8): name + Change, glyph,
/// the preset's editable steppers (reps and recovery only, D2), the
/// warm-up caption and "Save as custom". Custom templates and fartlek show
/// their structure; a custom template is edited in the builder.
class _SessionCard extends StatelessWidget {
  const _SessionCard({
    required this.spec,
    required this.settings,
    required this.onChange,
    required this.onEdit,
    required this.onSaveAsCustom,
  });

  final engine.SessionSpec spec;
  final AppSettings settings;
  final VoidCallback onChange;
  final Future<void> Function(AppSettings Function(AppSettings)) onEdit;
  final VoidCallback onSaveAsCustom;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final preset = engine.SessionCatalogue.byId(spec.templateId);
    final fartlek = spec.templateId == engine.SessionSpec.fartlekId;
    final rec = spec.steps.where((s) => !s.isWork).firstOrNull;
    final reps = spec.repCount;
    final canSaveAsCustom =
        !fartlek && SessionChoice.asCustom(spec, 'x') != null;

    Future<void> edit({int? reps, engine.SessionStep? recovery}) {
      final p = preset!;
      if (p.id == engine.SessionSpec.norwegian4x4Id) {
        return onEdit(
          (x) => x.copyWith(
            reps: reps == null ? null : PresetRules.clampReps(reps),
            recoverySeconds: recovery == null
                ? null
                : PresetRules.clampRecovery(recovery.value),
          ),
        );
      }
      return onEdit((x) {
        final old = x.presetEdits[p.id];
        final next = PresetEdit(
          reps: reps ?? old?.reps,
          recovery: recovery ?? old?.recovery,
        );
        return x.copyWith(presetEdits: {...x.presetEdits, p.id: next});
      });
    }

    final children = <Widget>[
      Row(
        children: [
          Expanded(
            child: Text(
              spec.name.toUpperCase(),
              key: const ValueKey('session-name'),
              style: RunSoloType.title28.copyWith(color: t.inkPrimary),
            ),
          ),
          TextButton(
            key: const ValueKey('session-change'),
            style: TextButton.styleFrom(minimumSize: const Size(56, 56)),
            onPressed: onChange,
            child: Text(
              'Change ›',
              style: RunSoloType.body15.copyWith(color: t.inkPrimary),
            ),
          ),
        ],
      ),
      if (!fartlek) ...[
        StructureGlyph(spec: spec, height: 20),
        const SizedBox(height: Space.x8),
      ],
      Text(
        SessionText.structure(spec),
        style: RunSoloType.body15.copyWith(color: t.inkSecondary),
      ),
    ];

    if (preset != null && preset.repsEditable) {
      children.add(
        ValueStepper(
          label: 'Reps',
          value: '$reps',
          onMinus: reps > preset.minReps! ? () => edit(reps: reps - 1) : null,
          onPlus: reps < preset.maxReps! ? () => edit(reps: reps + 1) : null,
        ),
      );
    }
    if (preset != null && preset.recoveryEditable && rec != null) {
      final distance = rec.target == engine.TargetKind.distance;
      final range = distance
          ? preset.recoveryDistanceRange
          : preset.recoveryRange;
      if (preset.recoveryRange != null &&
          preset.recoveryDistanceRange != null) {
        // 8 × 400 m: recovery by metres or minutes (plan §3.1).
        children.add(
          _Choice(
            label: 'Recovery by',
            left: 'Distance',
            right: 'Time',
            leftSelected: distance,
            onLeft: () => edit(
              recovery: engine.SessionStep.recoveryDistance(200, rep: 1),
            ),
            onRight: () =>
                edit(recovery: engine.SessionStep.recovery(90, rep: 1)),
          ),
        );
      }
      if (range != null) {
        final step = distance
            ? SessionRules.distanceStep
            : SessionRules.timeStep;
        engine.SessionStep withValue(int v) => distance
            ? engine.SessionStep.recoveryDistance(v, rep: 1, style: rec.style)
            : engine.SessionStep.recovery(v, rep: 1, style: rec.style);
        children.add(
          ValueStepper(
            label: 'Recovery',
            value: SessionText.target(rec),
            onMinus: rec.value > range.$1
                ? () => edit(
                    recovery: withValue(
                      (rec.value - step).clamp(range.$1, range.$2),
                    ),
                  )
                : null,
            onPlus: rec.value < range.$2
                ? () => edit(
                    recovery: withValue(
                      (rec.value + step).clamp(range.$1, range.$2),
                    ),
                  )
                : null,
          ),
        );
      }
    }

    children.add(const SizedBox(height: Space.x8));
    children.add(
      Text(
        fartlek
            ? 'Press LAP at the start and end of each surge. You get a '
                  'surge summary, not a verdict.'
            : spec.warmupSeconds == null
            ? 'Warm-up: open. Tap START REPS when you are ready.'
            : spec.warmupSeconds == 0
            ? 'No warm-up. The clock starts when you tap Start.'
            : 'Warm-up: ${SessionText.clock(spec.warmupSeconds!)}, then the '
                  'reps start on their own.',
        style: RunSoloType.body15.copyWith(color: t.inkSecondary),
      ),
    );
    if (SessionChoice.needsGps(spec)) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: Space.x8),
          child: Text(
            'Distance reps need GPS. START REPS waits for a fix.',
            key: const ValueKey('session-gps-note'),
            style: RunSoloType.label13.copyWith(color: t.semWarn),
          ),
        ),
      );
    }
    if (canSaveAsCustom) {
      children.add(
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const ValueKey('session-save-custom'),
            style: TextButton.styleFrom(
              minimumSize: const Size(56, 48),
              padding: EdgeInsets.zero,
            ),
            onPressed: onSaveAsCustom,
            child: Text(
              preset != null
                  ? 'Anything else: Save as custom ›'
                  : 'Edit in the builder ›',
              style: RunSoloType.body15.copyWith(color: t.inkPrimary),
            ),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.left,
    required this.right,
    required this.leftSelected,
    required this.onLeft,
    required this.onRight,
  });
  final String label;
  final String left;
  final String right;
  final bool leftSelected;
  final VoidCallback onLeft;
  final VoidCallback onRight;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    Widget seg(String text, bool selected, VoidCallback onTap) => Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        child: InkWell(
          key: ValueKey('choice-$text'),
          borderRadius: BorderRadius.circular(Radii.chip),
          onTap: selected ? null : onTap,
          child: Container(
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? t.inkPrimary : t.bgRaised,
              borderRadius: BorderRadius.circular(Radii.chip),
              border: Border.all(color: t.lineHair),
            ),
            child: Text(
              text,
              style: RunSoloType.label13.copyWith(
                fontSize: 15,
                color: selected ? t.bgBase : t.inkPrimary,
              ),
            ),
          ),
        ),
      ),
    );
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
              seg(left, leftSelected, onLeft),
              const SizedBox(width: Space.x8),
              seg(right, !leftSelected, onRight),
            ],
          ),
        ],
      ),
    );
  }
}
