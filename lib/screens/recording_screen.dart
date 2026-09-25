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
import '../widgets/lap_button.dart';
import '../widgets/pace_dial.dart';
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
        // Plan §4: keep the backed-up set under budget after each finalise.
        // Best effort; the archive is still indexed by the store.
        unawaited(
          _services!.storage.enforceBackupBudget().catchError(
            (_) => <String>[],
          ),
        );
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
          final compact = MediaQuery.sizeOf(context).height < 720;
          final lapHeight = compact ? 160.0 : 200.0;
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
                        _Header(s: s, maxHr: maxHr, compact: compact),
                        if (_stopError != null)
                          _Banner(text: _stopError!, color: t.semDanger)
                        else if (s.fault != null)
                          _Banner(text: s.fault!, color: t.semDanger)
                        else if (s.gpsLost)
                          _Banner(text: gpsBannerCopy(s), color: t.semWarn)
                        else if (s.notice != null)
                          _Banner(text: s.notice!, color: t.semWarn),
                        const Spacer(),
                        if (s.isPreset) ...[
                          // 4x4 (founder field test 25-Sep): no big LAP.
                          // Warm-up → big START 4x4; then the phases run on
                          // their own and the screen shows the countdown,
                          // the segment's average pace and the current-pace
                          // dial. Lock-screen LAP still re-aligns a phase.
                          // Timed phases (founder, tester 0.2): the segment
                          // average is the primary number, at least as big
                          // as the countdown; one step smaller on short
                          // screens so both fit at 360 x 640.
                          _TimerBlock(
                            s: s,
                            ctl: ctl,
                            style: s.phase == Phase.warmup
                                ? null
                                : (compact
                                      ? RunSoloType.display64
                                      : RunSoloType.display96),
                          ),
                          const Spacer(),
                          Visibility(
                            visible: !s.paused,
                            maintainSize: true,
                            maintainAnimation: true,
                            maintainState: true,
                            child: s.phase == Phase.warmup
                                ? _Stats(s: s, units: settings.units)
                                : _SegmentPace(
                                    s: s,
                                    ctl: ctl,
                                    units: settings.units,
                                    compact: compact,
                                  ),
                          ),
                        ] else if (s.lapsEnabled) ...[
                          _TimerBlock(s: s, ctl: ctl),
                          const Spacer(),
                          // The PAUSED card sits here; keep the space, hide
                          // the numbers so nothing peeks out around it.
                          Visibility(
                            visible: !s.paused,
                            maintainSize: true,
                            maintainAnimation: true,
                            maintainState: true,
                            child: _Stats(s: s, units: settings.units),
                          ),
                        ] else
                          _FreeRunBlock(
                            s: s,
                            ctl: ctl,
                            units: settings.units,
                            maxHr: maxHr,
                            compact: compact,
                          ),
                        const SizedBox(height: Space.x12),
                        Visibility(
                          visible: !s.paused,
                          maintainSize: true,
                          maintainAnimation: true,
                          maintainState: true,
                          child: GpsBar(
                            accuracyM: s.gpsAccuracyM,
                            lost: s.gpsLost,
                          ),
                        ),
                        const SizedBox(height: Space.x16),
                        if (s.isPreset && s.phase == Phase.warmup)
                          LapButton(
                            key: const ValueKey('start-reps'),
                            label: 'START 4x4',
                            onLap: ctl.startReps,
                            pulse: ctl.lapPulse,
                            haptics: settings.haptics,
                            height: lapHeight,
                          )
                        else if (s.isPreset)
                          const Spacer()
                        else if (s.lapsEnabled)
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

/// `repIndex` is 1-based in work / recovery (RecorderCore.kt); the last rep
/// goes straight to cool-down, so recoveries count to `reps - 1` (brief
/// §4.4 "Recovery 2 of 3").
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
    Phase.recovery => 'RECOVERY ${s.repIndex} OF ${s.reps - 1}',
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
  // Total time has its own large cell in the vitals row (tester 0.2).
  if (!s.isPreset) return 'this lap';
  return switch (s.phase) {
    Phase.warmup => 'warm up, then tap START 4x4',
    Phase.work => 'remaining in rep',
    Phase.recovery => 'remaining in recovery',
    Phase.cooldown => 'hold Stop when done',
    Phase.none => '',
  };
}

class _Header extends StatelessWidget {
  const _Header({required this.s, required this.maxHr, this.compact = false});
  final RecordingSnapshot s;
  final int maxHr;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    // A1: labels render in Bone (or Bone 70 %) on a zone background.
    final onZone = s.zone > 0;
    final secondary = onZone ? HrZones.secondaryOnZone : t.inkSecondary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (s.hrPaired) ...[
          ZoneHeader(
            zone: s.zone,
            paired: s.hrPaired,
            // A1: the label reads the strap state as soon as the reading
            // drops; the background keeps the last zone until the tracker's
            // 5 s loss rule.
            dropped: s.hr == null,
            onZoneBackground: onZone,
          ),
          const SizedBox(height: Space.x4),
        ],
        Text(
          phaseTitle(s),
          style: RunSoloType.title28.copyWith(color: t.inkPrimary),
        ),
        const SizedBox(height: Space.x8),
        // Founder (tester 0.2): heart rate and total time readable at arm's
        // length, not top-bar text. Free run's big timer already is the
        // total, so it shows heart rate only.
        _Vitals(
          s: s,
          maxHr: maxHr,
          showTotal: s.mode != RecordMode.free,
          compact: compact,
          secondary: secondary,
        ),
        const SizedBox(height: Space.x8),
      ],
    );
  }
}

/// Heart rate and total time as a row of large tabular figures with small
/// labels (founder, tester 0.2). Bone digits on every zone background
/// (≥ 7:1, zone contrast test); a dropped strap reads "--" + reconnecting in
/// warn, never 0.
class _Vitals extends StatelessWidget {
  const _Vitals({
    required this.s,
    required this.maxHr,
    required this.showTotal,
    required this.compact,
    required this.secondary,
  });
  final RecordingSnapshot s;
  final int maxHr;
  final bool showTotal;
  final bool compact;
  final Color secondary;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final number = RunSoloType.display44.copyWith(
      color: t.inkPrimary,
      fontSize: compact ? 36 : 44,
    );
    final label = RunSoloType.micro11.copyWith(color: secondary);
    final hr = s.hr;
    final pct = hr == null || maxHr <= 0 ? null : (hr * 100 / maxHr).round();
    Widget cell(String title, Widget value, {IconData? icon}) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 12, color: t.hrZone),
              const SizedBox(width: Space.x4),
            ],
            Text(title, style: label),
          ],
        ),
        value,
      ],
    );
    final cells = <Widget>[
      if (s.hrPaired)
        Expanded(
          child: Semantics(
            label: hr == null
                ? 'Heart rate strap reconnecting'
                : 'Heart rate $hr',
            child: cell(
              'HEART RATE',
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    hr == null ? '--' : '$hr',
                    key: const ValueKey('vitals-hr'),
                    style: hr == null
                        ? number.copyWith(color: secondary)
                        : number,
                  ),
                  const SizedBox(width: Space.x8),
                  Flexible(
                    child: Text(
                      hr == null ? 'reconnecting' : '$pct%',
                      softWrap: false,
                      overflow: TextOverflow.fade,
                      style: RunSoloType.body15.copyWith(
                        color: hr == null ? t.semWarn : secondary,
                      ),
                    ),
                  ),
                ],
              ),
              icon: Icons.favorite,
            ),
          ),
        ),
      if (showTotal)
        Expanded(
          child: cell(
            'TOTAL',
            Text(
              Fmt.clock(s.elapsedMs),
              key: const ValueKey('vitals-total'),
              softWrap: false,
              style: number,
            ),
          ),
        ),
    ];
    if (cells.isEmpty) return const SizedBox.shrink();
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: cells);
  }
}

/// Free run (A2): exactly four numbers, no lap counter, no ghost line.
class _FreeRunBlock extends StatelessWidget {
  const _FreeRunBlock({
    required this.s,
    required this.ctl,
    required this.units,
    required this.maxHr,
    this.compact = false,
  });
  final RecordingSnapshot s;
  final RecordingController ctl;
  final Units units;
  final int maxHr;

  /// Short screen (< 720 dp): each number one step down.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final secondary = s.zone > 0 ? HrZones.secondaryOnZone : t.inkSecondary;
    final activeMs = ctl.displayElapsedMs;
    final runAverage = s.totalDistanceM > 20 && activeMs > 0
        ? activeMs / 1000 / (s.totalDistanceM / 1000)
        : null;
    return Column(
      key: const ValueKey('free-run-block'),
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            Fmt.clock(ctl.displayElapsedMs),
            key: const ValueKey('timer'),
            softWrap: false,
            style: (compact ? RunSoloType.display96 : RunSoloType.timer120)
                .copyWith(color: t.inkPrimary),
          ),
        ),
        SizedBox(height: compact ? Space.x8 : Space.x24),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            Fmt.distance(s.totalDistanceM, units),
            softWrap: false,
            style: (compact ? RunSoloType.display64 : RunSoloType.display96)
                .copyWith(color: t.inkPrimary),
          ),
        ),
        const SizedBox(height: Space.x8),
        // Founder 25-Sep: the current-pace dial here too, needle against the
        // run's average so far.
        SizedBox(
          width: compact ? 150 : 200,
          child: PaceDial(
            currentSecPerKm: s.livePaceSecPerKm,
            referenceSecPerKm: runAverage,
            units: units,
            onZone: s.zone > 0,
          ),
        ),
        Text(
          runAverage == null
              ? 'average from 20 m'
              : 'run average ${Fmt.paceUnit(runAverage, units)}',
          style: RunSoloType.body15.copyWith(color: secondary),
        ),
      ],
    );
  }
}

class _TimerBlock extends StatelessWidget {
  const _TimerBlock({required this.s, required this.ctl, this.style});
  final RecordingSnapshot s;
  final RecordingController ctl;

  /// Digits style; timer120 unless a bigger primary number shares the screen.
  final TextStyle? style;

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
        style: (style ?? RunSoloType.timer120).copyWith(
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
          s.paused ? '' : timerCaption(s),
          style: RunSoloType.label13.copyWith(color: secondary),
        ),
      ],
    );
  }
}

/// 4x4 in a timed phase (A2 revised, founder 25-Sep; tester 0.2): the
/// segment's average pace is the primary number, full width and at least
/// the countdown's size so it reads at arm's length mid-rep. Under it, the
/// distance / last rep on the left and the current-pace dial on the right,
/// referenced to the last rep's pace (or the segment average until there
/// is one).
class _SegmentPace extends StatelessWidget {
  const _SegmentPace({
    required this.s,
    required this.ctl,
    required this.units,
    this.compact = false,
  });
  final RecordingSnapshot s;
  final RecordingController ctl;
  final Units units;

  /// Short screen (< 720 dp): every number one step down, same order.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final onZone = s.zone > 0;
    final secondary = onZone ? HrZones.secondaryOnZone : t.inkSecondary;
    final activeMs = ctl.displayLapElapsedMs;
    final segmentAvg = s.lapDistanceM > 20 && activeMs > 0
        ? activeMs / 1000 / (s.lapDistanceM / 1000)
        : null;
    final reference = s.phase == Phase.work
        ? (s.lastRepPaceSecPerKm ?? segmentAvg)
        : segmentAvg;
    final title = switch (s.phase) {
      Phase.work => 'REP AVERAGE',
      Phase.recovery => 'RECOVERY AVERAGE',
      _ => 'SEGMENT AVERAGE',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            Fmt.pace(segmentAvg, units),
            key: const ValueKey('segment-avg'),
            softWrap: false,
            // Larger than any other number on the screen; the FittedBox only
            // shrinks it for a wide value (10:05 /mi).
            style: RunSoloType.timer120.copyWith(
              color: t.inkPrimary,
              fontWeight: FontWeight.w700,
              fontSize: compact ? 128 : 168,
            ),
          ),
        ),
        Text(
          '$title /${units == Units.mi ? 'mi' : 'km'}',
          style: RunSoloType.label13.copyWith(color: secondary),
        ),
        SizedBox(height: compact ? Space.x8 : Space.x16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Text(
                s.lastRepPaceSecPerKm == null
                    ? Fmt.distance(s.lapDistanceM, units)
                    : '${Fmt.distance(s.lapDistanceM, units)}\nlast rep '
                          '${Fmt.pace(s.lastRepPaceSecPerKm, units)}',
                style: RunSoloType.body17.copyWith(color: secondary),
              ),
            ),
            const SizedBox(width: Space.x16),
            SizedBox(
              width: compact ? 112 : 136,
              child: PaceDial(
                currentSecPerKm: s.livePaceSecPerKm,
                referenceSecPerKm: reference,
                units: units,
                onZone: onZone,
                paceStyle: RunSoloType.display44,
              ),
            ),
          ],
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
                  : (s.isPreset ? 'warm-up pace' : 'first lap'),
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
        child: Container(
          // Solid card: the numbers behind move with the mode and screen
          // height, so PAUSED must never sit on top of them.
          margin: const EdgeInsets.symmetric(horizontal: Space.x24),
          padding: const EdgeInsets.all(Space.x24),
          decoration: BoxDecoration(
            color: t.bgBase,
            borderRadius: BorderRadius.circular(Radii.lap),
          ),
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
