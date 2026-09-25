import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/format.dart';
import '../app/routes.dart';
import '../app/services.dart';
import '../platform/gateway.dart';
import '../state/recording_controller.dart';
import '../theme/theme.dart';
import '../theme/zones.dart';
import '../widgets/delta_glyph.dart';
import '../widgets/gps_bar.dart';
import '../widgets/hold_button.dart';
import '../widgets/hr_badge.dart';
import '../widgets/lap_button.dart';
import '../widgets/zone_gauge.dart';

/// Record screen (design brief §4.4, addendum A1/A2): three layouts on one
/// screen. 4x4 = countdown + LAP; Laps run = count-up + LAP; Free run = no
/// LAP, the 200 dp go to time / distance / pace / HR. The background follows
/// the HR zone from the engine tracker (600 ms crossfade, 160 ms reduced;
/// never a black frame after a wake because the controller seeds the last
/// zone). Timer counts down in a timed phase, up otherwise. No animation
/// runs except M2 (LAP ring), M3 (rep-complete invert) and the zone fade.
/// Buttons only, no gestures.
class RecordingScreen extends StatefulWidget {
  const RecordingScreen({super.key});

  @override
  State<RecordingScreen> createState() => _RecordingScreenState();
}

class _RecordingScreenState extends State<RecordingScreen>
    with SingleTickerProviderStateMixin {
  RecordingController? _ctl;
  AppServices? _services;
  Timer? _clock;
  bool _stopping = false;
  String? _stopError;
  bool _wakelock = false;

  /// M3: 120 ms Bone flash when a work rep ends.
  late final AnimationController _invert = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 120),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ctl != null) return;
    _services = AppServices.of(context);
    _ctl = _services!.recording;
    _ctl!.repCompletePulse.addListener(_onRepComplete);
    _ctl!.repStartPulse.addListener(_onRepStart);
    _ctl!.addListener(_onSnapshot);
    _ctl!.attach();
    _applyKeepScreenOn();
    _clock = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted && _ctl!.snapshot.recording) setState(() {});
    });
  }

  bool get _haptics => AppServices.of(context).settings.settings.haptics;

  bool get _reduced =>
      MediaQuery.disableAnimationsOf(context) ||
      AppServices.of(context).settings.settings.reducedMotion;

  void _onRepComplete() {
    // One long vibrate here; the double pulse and countdown haptics are the
    // service's cue scheduler (plan §3), which also runs screen-off.
    if (_haptics) HapticFeedback.vibrate();
    if (!_reduced) {
      _invert.forward(from: 0).then((_) => _invert.reverse());
    }
  }

  void _onRepStart() {
    if (_haptics) HapticFeedback.heavyImpact();
  }

  /// FLAG_KEEP_SCREEN_ON resets when the Activity is recreated, so it is set
  /// on init and again on every state change while active.
  void _applyKeepScreenOn() {
    final services = _services!;
    final on = services.settings.settings.keepScreenOn && _ctl!.snapshot.active;
    if (on == _wakelock) return;
    _wakelock = on;
    services.permissions.setKeepScreenOn(on).catchError((_) {});
  }

  /// The service discarded the run (`FaultKind.startFailed`): nothing to
  /// save, back to Start with the message.
  void _onSnapshot() {
    final s = _ctl!.snapshot;
    _applyKeepScreenOn();
    if (s.discarded && mounted && !_stopping) {
      _stopping = true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.fault ?? 'Recording could not start.')),
      );
      Navigator.of(context).pop();
    }
  }

  Future<void> _stop() async {
    if (_stopping) return;
    setState(() {
      _stopping = true;
      _stopError = null;
    });
    try {
      final id = await _ctl!.stop();
      if (!mounted) return;
      if (id == null) {
        Navigator.of(context).pop();
      } else {
        // Verdict / summary replaces the record screen (design brief §4.6).
        Navigator.of(context)
            .pushReplacementNamed(Routes.verdictJustFinished, arguments: id);
      }
    } catch (e) {
      // The journal still holds the run; recovery offers it on next open.
      // Never trap the runner behind the SAVING overlay.
      if (mounted) {
        setState(() {
          _stopping = false;
          // The service is still recording (the journal is intact), so a
          // second hold retries; recovery only lists runs that are not live.
          _stopError =
              'Could not save right now. Still recording. '
              'Hold Stop again.';
        });
      }
    }
  }

  @override
  void dispose() {
    if (_wakelock) {
      _services?.permissions.setKeepScreenOn(false).catchError((_) {});
    }
    _ctl?.removeListener(_onSnapshot);
    _clock?.cancel();
    _ctl?.repCompletePulse.removeListener(_onRepComplete);
    _ctl?.repStartPulse.removeListener(_onRepStart);
    _invert.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final ctl = _ctl!;
    final services = AppServices.of(context);
    final settings = services.settings.settings;
    final maxHr = services.maxHr.maxHr;
    final reduced = _reduced;
    return PopScope(
      canPop: false,
      child: ListenableBuilder(
        listenable: ctl,
        builder: (context, _) {
          final s = ctl.snapshot;
          final zoneBg = HrZones.background(s.zone);
          final lapHeight = MediaQuery.sizeOf(context).height < 720
              ? 160.0
              : 200.0;
          return Scaffold(
            backgroundColor: Colors.transparent,
            body: Stack(
              fit: StackFit.expand,
              children: [
                // A1: zone background, 600 ms `e.standard` crossfade (160 ms
                // reduced). Zone changes are already dwell-gated upstream.
                AnimatedContainer(
                  key: const ValueKey('zone-background'),
                  duration: reduced
                      ? MotionDurations.quick
                      : const Duration(milliseconds: 600),
                  curve: MotionCurves.standard,
                  color: zoneBg,
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Space.recordGutter,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: Space.x12),
                        _Header(s: s, maxHr: maxHr),
                        if (_stopError != null)
                          _Banner(text: _stopError!, color: t.semDanger)
                        else if (s.fault != null)
                          _Banner(text: s.fault!, color: t.semDanger)
                        else if (s.gpsLost)
                          _Banner(text: gpsBannerCopy(s), color: t.semWarn),
                        const Spacer(),
                        if (s.lapsEnabled) ...[
                          _TimerBlock(s: s, ctl: ctl),
                          const Spacer(),
                          _Stats(s: s, units: settings.units),
                        ] else
                          _FreeRunBlock(
                            s: s,
                            ctl: ctl,
                            units: settings.units,
                            maxHr: maxHr,
                          ),
                        const SizedBox(height: Space.x12),
                        GpsBar(accuracyM: s.gpsAccuracyM, lost: s.gpsLost),
                        const SizedBox(height: Space.x16),
                        if (s.lapsEnabled)
                          LapButton(
                            onLap: ctl.lap,
                            pulse: ctl.lapPulse,
                            haptics: settings.haptics,
                            height: lapHeight,
                          )
                        else
                          const Spacer(),
                        const SizedBox(height: Space.x12),
                        Row(
                          children: [
                            Expanded(
                              child: _PauseButton(
                                paused: s.paused,
                                onTap: s.paused ? ctl.resume : ctl.pause,
                              ),
                            ),
                            const SizedBox(width: Space.x12),
                            Expanded(
                              child: HoldButton(
                                label: 'HOLD TO STOP',
                                icon: Icons.stop,
                                onHeld: _stop,
                                haptics: settings.haptics,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: Space.x16),
                      ],
                    ),
                  ),
                ),
                if (s.paused) _PausedOverlay(onResume: ctl.resume),
                IgnorePointer(
                  child: FadeTransition(
                    opacity: _invert,
                    child: ColoredBox(color: t.inkPrimary),
                  ),
                ),
                if (_stopping)
                  ColoredBox(
                    color: t.bgBase.withValues(alpha: 0.7),
                    child: Center(
                      child: Text(
                        'SAVING',
                        style: RunSoloType.title28.copyWith(
                          color: t.inkSecondary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// `repIndex` is 1-based in work / recovery (RecorderCore.kt); a recovery
/// follows the last rep too, so recoveries count to `reps`.
String phaseTitle(RecordingSnapshot s) {
  switch (s.mode) {
    case RecordMode.laps:
      return 'LAP ${s.lapIndex + 1}';
    case RecordMode.free:
      return 'FREE RUN';
    case RecordMode.cooper:
      return '12-MINUTE TEST';
    case RecordMode.fourByFour:
      break;
  }
  if (!s.isPreset) return 'LAP ${s.lapIndex + 1}';
  return switch (s.phase) {
    Phase.warmup => 'WARM-UP',
    Phase.work => 'REP ${s.repIndex} OF ${s.reps}',
    Phase.recovery => 'RECOVERY ${s.repIndex} OF ${s.reps}',
    Phase.cooldown => 'COOL-DOWN',
    Phase.none => '4x4',
  };
}

/// "Rep flagged" only means something inside a rep; elsewhere say what it is.
String gpsBannerCopy(RecordingSnapshot s) {
  if (!s.hadFix) return 'Waiting for GPS';
  if (s.phase == Phase.work) return 'GPS dropped, this rep is flagged';
  return 'GPS dropped';
}

String timerCaption(RecordingSnapshot s) {
  if (!s.isPreset) return 'this lap · total ${Fmt.clock(s.elapsedMs)}';
  return switch (s.phase) {
    Phase.warmup => 'tap LAP when ready',
    Phase.work => 'remaining in rep',
    Phase.recovery => 'remaining in recovery',
    Phase.cooldown => 'hold Stop when done',
    Phase.none => '',
  };
}

class _Header extends StatelessWidget {
  const _Header({required this.s, required this.maxHr});
  final RecordingSnapshot s;
  final int maxHr;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    // A1: labels render in Bone (or Bone 70 %) on a zone background.
    final onZone = s.zone > 0;
    final secondary = onZone ? HrZones.secondaryOnZone : t.inkSecondary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: s.hrPaired
                  ? ZoneHeader(
                      zone: s.zone,
                      paired: s.hrPaired,
                      onZoneBackground: onZone,
                    )
                  : Text(
                      'TOTAL ${Fmt.clock(s.elapsedMs)}',
                      style: RunSoloType.micro11.copyWith(color: secondary),
                    ),
            ),
            HrBadge(hr: s.hr, paired: s.hrPaired, maxHr: maxHr, onZone: onZone),
          ],
        ),
        const SizedBox(height: Space.x4),
        Row(
          children: [
            Expanded(
              child: Text(
                phaseTitle(s),
                style: RunSoloType.title28.copyWith(color: t.inkPrimary),
              ),
            ),
            if (s.hrPaired && s.lapsEnabled)
              Text(
                'TOTAL ${Fmt.clock(s.elapsedMs)}',
                style: RunSoloType.micro11.copyWith(color: secondary),
              ),
          ],
        ),
      ],
    );
  }
}

/// Free run (A2): exactly four numbers, no lap counter, no ghost line.
class _FreeRunBlock extends StatelessWidget {
  const _FreeRunBlock({
    required this.s,
    required this.ctl,
    required this.units,
    required this.maxHr,
  });
  final RecordingSnapshot s;
  final RecordingController ctl;
  final Units units;
  final int maxHr;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final secondary = s.zone > 0 ? HrZones.secondaryOnZone : t.inkSecondary;
    final pct = s.hr == null || maxHr <= 0
        ? null
        : (s.hr! * 100 / maxHr).round();
    return Column(
      key: const ValueKey('free-run-block'),
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            Fmt.clock(ctl.displayElapsedMs),
            key: const ValueKey('timer'),
            softWrap: false,
            style: RunSoloType.timer120.copyWith(color: t.inkPrimary),
          ),
        ),
        const SizedBox(height: Space.x24),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            Fmt.distance(s.totalDistanceM, units),
            softWrap: false,
            style: RunSoloType.display96.copyWith(color: t.inkPrimary),
          ),
        ),
        const SizedBox(height: Space.x8),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            Fmt.paceUnit(s.livePaceSecPerKm, units),
            softWrap: false,
            style: RunSoloType.display64.copyWith(color: t.inkPrimary),
          ),
        ),
        const SizedBox(height: Space.x8),
        if (s.hrPaired)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.favorite, size: 16, color: t.hrZone),
              const SizedBox(width: Space.x8),
              Text(
                s.hr == null ? '-- · reconnecting' : '${s.hr} · $pct%',
                style: RunSoloType.body17.copyWith(
                  color: s.hr == null ? t.semWarn : secondary,
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _TimerBlock extends StatelessWidget {
  const _TimerBlock({required this.s, required this.ctl});
  final RecordingSnapshot s;
  final RecordingController ctl;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final secondary = s.zone > 0 ? HrZones.secondaryOnZone : t.inkSecondary;
    final recovery = s.phase == Phase.recovery;
    final ms = s.timed ? ctl.displayRemainingMs : ctl.displayLapElapsedMs;
    final total = recovery && s.preset != null
        ? s.preset!.recoverySeconds * 1000
        : 0;
    // Scales down only when the digits would not fit (hour-long runs,
    // narrow phones); the 120 px face is the normal case.
    final digits = FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(
        Fmt.clock(ms),
        key: const ValueKey('timer'),
        softWrap: false,
        style: RunSoloType.timer120.copyWith(
          color: recovery ? secondary : t.inkPrimary,
        ),
        textAlign: TextAlign.center,
      ),
    );
    return Column(
      children: [
        if (recovery)
          CustomPaint(
            painter: _RecoveryRingPainter(
              progress: total == 0 ? 0 : 1 - ms / total,
              color: secondary,
              track: t.lineHair,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                vertical: Space.x12,
                horizontal: Space.x24,
              ),
              child: digits,
            ),
          )
        else
          digits,
        const SizedBox(height: Space.x8),
        Text(
          timerCaption(s),
          style: RunSoloType.label13.copyWith(color: secondary),
        ),
      ],
    );
  }
}

class _Stats extends StatelessWidget {
  const _Stats({required this.s, required this.units});
  final RecordingSnapshot s;
  final Units units;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final live = s.livePaceSecPerKm;
    final last = s.lastRepPaceSecPerKm;
    final showGhost = last != null;
    final onZone = s.zone > 0;
    Color deltaColor = onZone ? HrZones.secondaryOnZone : t.inkSecondary;
    String? delta;
    DeltaDirection? direction;
    if (showGhost && live != null) {
      delta = Fmt.deltaVsLast(live, last, units);
      final d = live - last;
      direction = DeltaGlyph.forDelta(d);
      // A1: Vermillion and Arc deltas are Bone with the arrow on a zone
      // background (Vermillion drops to 4.1:1 on Z3).
      deltaColor = onZone
          ? t.inkPrimary
          : d < -1
          ? t.semFaster
          : d > 1
          ? t.semSlower
          : t.semHolding;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.bottomLeft,
                child: Text(
                  Fmt.pace(live, units),
                  softWrap: false,
                  style: RunSoloType.display44.copyWith(color: t.inkPrimary),
                ),
              ),
            ),
            const SizedBox(width: Space.x4),
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '/${units == Units.mi ? 'mi' : 'km'}',
                style: RunSoloType.label13.copyWith(
                  color: onZone ? HrZones.secondaryOnZone : t.inkSecondary,
                ),
              ),
            ),
            const SizedBox(width: Space.x16),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.bottomRight,
                child: Text(
                  Fmt.distance(s.lapDistanceM, units),
                  softWrap: false,
                  style: RunSoloType.display44.copyWith(color: t.inkPrimary),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: Space.x4),
        Row(
          children: [
            Text(
              showGhost
                  ? '${s.isPreset ? 'last rep' : 'last lap'} ${Fmt.pace(last, units)}'
                  : (s.isPreset ? 'first rep sets the pace' : 'first lap'),
              style: RunSoloType.body15.copyWith(color: deltaColor),
            ),
            if (direction != null && delta != null) ...[
              const SizedBox(width: Space.x8),
              DeltaGlyph(direction: direction, color: deltaColor, size: 11),
              const SizedBox(width: Space.x4),
              Text(
                delta,
                style: RunSoloType.body15.copyWith(color: deltaColor),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Container(
      margin: const EdgeInsets.only(top: Space.x12),
      padding: const EdgeInsets.symmetric(
        horizontal: Space.x12,
        vertical: Space.x8,
      ),
      decoration: BoxDecoration(
        color: t.bgRaised,
        borderRadius: BorderRadius.circular(Radii.chip),
        border: Border(left: BorderSide(color: color, width: 4)),
      ),
      child: Text(
        text,
        style: RunSoloType.label13.copyWith(color: t.inkPrimary),
      ),
    );
  }
}

class _PauseButton extends StatelessWidget {
  const _PauseButton({required this.paused, required this.onTap});
  final bool paused;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Semantics(
      button: true,
      label: paused ? 'Resume' : 'Pause',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.button),
        child: Container(
          height: 56,
          decoration: BoxDecoration(
            color: t.bgRaised,
            borderRadius: BorderRadius.circular(Radii.button),
            border: Border.all(color: t.lineHair),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                paused ? Icons.play_arrow : Icons.pause,
                size: 20,
                color: t.inkPrimary,
              ),
              const SizedBox(width: Space.x8),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    paused ? 'RESUME' : 'PAUSE',
                    softWrap: false,
                    style: RunSoloType.label13.copyWith(
                      color: t.inkPrimary,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Paused: dim to 60%, one big RESUME (design brief §4.4).
class _PausedOverlay extends StatelessWidget {
  const _PausedOverlay({required this.onResume});
  final Future<void> Function() onResume;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return ColoredBox(
      color: t.bgBase.withValues(alpha: 0.6),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.x32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'PAUSED',
                style: RunSoloType.display44.copyWith(color: t.inkSecondary),
              ),
              const SizedBox(height: Space.x24),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(96),
                  textStyle: RunSoloType.display44,
                ),
                onPressed: onResume,
                child: const Text('RESUME'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecoveryRingPainter extends CustomPainter {
  _RecoveryRingPainter({
    required this.progress,
    required this.color,
    required this.track,
  });
  final double progress;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(2);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(24));
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = track,
    );
    final path = Path()..addRRect(rrect);
    for (final m in path.computeMetrics()) {
      canvas.drawPath(
        m.extractPath(0, m.length * progress.clamp(0, 1)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_RecoveryRingPainter old) => old.progress != progress;
}
