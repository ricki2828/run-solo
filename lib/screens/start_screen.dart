import 'package:flutter/material.dart';

import '../app/format.dart';
import '../app/routes.dart';
import '../app/services.dart';
import '../platform/gateway.dart';
import '../state/recording_controller.dart';
import '../state/settings.dart';
import '../theme/theme.dart';
import '../widgets/chrome.dart';
import '../widgets/mode_chip.dart';
import '../widgets/value_stepper.dart';

/// Start (plan §6, §18.2, design brief §4.5): three run types, 4x4 preset
/// editor (reps 3–6, work locked 4:00, recovery 2:00–5:00 in 15 s), cue
/// toggles, strap status, START. Typed start errors map to copy here;
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
    AppServices.of(context).permissions.volumeKeyLapsAvailable().then((ok) {
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
      result = await services.recording.start(s.lastMode, switch (s.lastMode) {
        RecordMode.fourByFour => s.preset,
        RecordMode.laps || RecordMode.free || RecordMode.cooper => null,
      }, s.units);
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
      case StartError.alreadyRunning:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final text = Theme.of(context).textTheme;
    final services = AppServices.of(context);
    return ListenableBuilder(
      listenable: services.settings,
      builder: (context, _) {
        final s = services.settings.settings;
        final mode = s.lastMode;
        final preset = mode == RecordMode.fourByFour;
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
                  reps: s.reps,
                  recoverySeconds: s.recoverySeconds,
                  onSelect: (m) => set((x) => x.copyWith(lastMode: m)),
                ),
                const SizedBox(height: Space.x24),
                if (preset) ...[
                  ValueStepper(
                    label: 'Reps',
                    value: '${s.reps}',
                    onMinus: s.reps > PresetRules.minReps
                        ? () => set((x) => x.copyWith(reps: x.reps - 1))
                        : null,
                    onPlus: s.reps < PresetRules.maxReps
                        ? () => set((x) => x.copyWith(reps: x.reps + 1))
                        : null,
                  ),
                  ValueStepper(
                    label: 'Rep',
                    value: Fmt.recovery(PresetRules.workSeconds),
                    lockedNote: 'Fixed at 4:00 in this version.',
                  ),
                  ValueStepper(
                    label: 'Recovery',
                    value: Fmt.recovery(s.recoverySeconds),
                    onMinus: s.recoverySeconds > PresetRules.minRecovery
                        ? () => set(
                            (x) => x.copyWith(
                              recoverySeconds: PresetRules.clampRecovery(
                                x.recoverySeconds - PresetRules.recoveryStep,
                              ),
                            ),
                          )
                        : null,
                    onPlus: s.recoverySeconds < PresetRules.maxRecovery
                        ? () => set(
                            (x) => x.copyWith(
                              recoverySeconds: PresetRules.clampRecovery(
                                x.recoverySeconds + PresetRules.recoveryStep,
                              ),
                            ),
                          )
                        : null,
                  ),
                  Text(
                    'Warm-up and cool-down are untimed: tap LAP when ready, '
                    'hold Stop when done.',
                    style: text.bodyMedium?.copyWith(color: t.inkSecondary),
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
                      style: text.bodyMedium?.copyWith(color: t.inkSecondary),
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
                const SizedBox(height: Space.x32),
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
                    RecordMode.fourByFour => 'START WARM-UP',
                    RecordMode.laps => 'START LAPS RUN',
                    RecordMode.free => 'START FREE RUN',
                    RecordMode.cooper => 'START TEST',
                  }),
                ),
                const SizedBox(height: Space.x24),
              ],
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
