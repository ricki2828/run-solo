import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/event_names.dart';
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

  /// The run this screen watched while it was live (auto-stop hand-off).
  String? _liveRunId;

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
    if (s.active && s.runId != null) _liveRunId = s.runId;
    // Auto-stop (K1 event at 5.00 km, plan §3.6): native ends the run on
    // its own; straight to the result, as after Hold to stop.
    final auto = _liveRunId;
    if (auto != null &&
        s.state == RecorderState.idle &&
        !s.discarded &&
        !_stopping &&
        mounted) {
      _stopping = true;
      unawaited(
        _services!.storage.enforceBackupBudget().catchError((_) => <String>[]),
      );
      Navigator.of(context)
          .pushReplacementNamed(Routes.verdictJustFinished, arguments: auto);
      return;
    }
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
          // 148 on short screens: the 36 sp last-lap line (A8) needs the room.
          final lapHeight = compact ? 148.0 : 200.0;
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
                        else if (s.gpsLost || s.showEndRep)
                          _Banner(text: gpsBannerCopy(s), color: t.semWarn)
                        else if (s.notice != null)
                          _Banner(text: s.notice!, color: t.semWarn),
                        const Spacer(),
                        if (isEventRun(s) && s.phase == Phase.work) ...[
                          // K1 / A10.10: distance to go is the biggest
                          // number, projected finish second; they swap for
                          // the last 400 m.
                          _PausedHidden(
                            paused: s.paused,
                            child: EventBlock(
                              s: s,
                              ctl: ctl,
                              units: settings.units,
                              compact: compact,
                              reduced: reduced,
                            ),
                          ),
                          const Spacer(),
                        ] else if (s.isPreset) ...[
                          // 4x4 (founder field test 25-Sep): no big LAP.
                          // Warm-up → big START 4x4; then the phases run on
                          // their own and the screen shows the countdown,
                          // the segment's average pace and the current-pace
                          // dial. Lock-screen LAP still re-aligns a phase.
                          // Timed phases (founder, tester 0.2 / 25-Sep): in
                          // a rep the rep average is the biggest number, in
                          // a recovery the countdown to the next rep is; one
                          // step smaller on short screens so both fit at
                          // 360 x 640.
                          _PausedHidden(
                            paused: s.paused,
                            child: _TimerBlock(
                              s: s,
                              ctl: ctl,
                              style: switch (s.phase) {
                                Phase.work => primaryStyle(
                                  compact,
                                  secondary: true,
                                ),
                                Phase.recovery => primaryStyle(compact),
                                _ => null,
                              },
                            ),
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
                          _PausedHidden(
                            paused: s.paused,
                            child: _TimerBlock(s: s, ctl: ctl),
                          ),
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
                        // END REP: the banner already says GPS is lost,
                        // and the short phone needs the bar's height.
                        if (!s.showEndRep) ...[
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
                        ],
                        const SizedBox(height: Space.x16),
                        if (s.isPreset &&
                            s.phase == Phase.warmup &&
                            s.needsGps &&
                            s.gpsLost)
                          // W3: distance reps cannot end without GPS, so
                          // START REPS waits for a fix.
                          _WaitingForGps(height: lapHeight)
                        else if (s.isPreset && s.phase == Phase.warmup)
                          LapButton(
                            key: const ValueKey('start-reps'),
                            label: 'START REPS',
                            onLap: ctl.startReps,
                            pulse: ctl.lapPulse,
                            haptics: settings.haptics,
                            height: lapHeight,
                          )
                        else if (s.isPreset && s.showEndRep)
                          // A8 / W3: a distance step with GPS weak or lost
                          // for > 10 s ends by hand.
                          LapButton(
                            key: const ValueKey('end-rep'),
                            label: 'END REP',
                            onLap: ctl.endRep,
                            pulse: ctl.lapPulse,
                            haptics: settings.haptics,
                            height: compact ? 96 : 120,
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

/// Metres to go (A8): whole metres, rounded down to 5 m under 100 m and
/// to 10 m above; holds at "0 m" until the auto-lap sample lands.
String metresText(double metres) {
  final m = metres.floor();
  final r = m < 100 ? m - m % 5 : m - m % 10;
  return '$r m';
}

/// Size of a 4x4 timed phase's two big numbers: the primary (rep average in
/// a rep, countdown in a recovery) and the secondary one. Short screens
/// (< 720 dp) step both down.
TextStyle primaryStyle(bool compact, {bool secondary = false}) => secondary
    ? (compact ? RunSoloType.display64 : RunSoloType.display96)
    : RunSoloType.timer120.copyWith(fontSize: compact ? 128 : 168);

/// `repIndex` is 1-based in work / recovery (RecorderCore.kt); the last rep
/// goes straight to cool-down, so recoveries count to `reps - 1` (brief
/// §4.4 "Recovery 2 of 3").
String phaseTitle(RecordingSnapshot s) {
  switch (s.mode) {
    case RecordMode.laps:
      // Fartlek (plan §3.5): the first LAP starts surge 1; odd laps are
      // surges, even laps easy.
      if (s.fartlek) {
        final n = s.lapIndex;
        if (n == 0) return 'EASY · LAP TO SURGE';
        return n.isOdd ? 'SURGE ${(n + 1) ~/ 2}' : 'EASY ${n ~/ 2}';
      }
      return 'LAP ${s.lapIndex + 1}';
    case RecordMode.free:
      return 'FREE RUN';
    case RecordMode.cooper:
      return '12-MINUTE TEST';
    case RecordMode.intervals:
      break;
  }
  if (!s.isPreset) return 'LAP ${s.lapIndex + 1}';
  if (isEventRun(s) && s.phase == Phase.work) {
    final name = kEventNames.parkrun.toUpperCase();
    return eventLastStretch(s) ? '$name · LAST 400 M' : '$name · 5 KM';
  }
  final step = s.currentStep;
  final detail = step == null ? '' : ' · ${stepDetail(step)}';
  return switch (s.phase) {
    Phase.warmup => 'WARM-UP',
    Phase.work => 'REP ${s.repIndex} OF ${s.reps}$detail',
    Phase.recovery => 'RECOVERY ${s.repIndex} OF ${s.reps - 1}$detail',
    Phase.cooldown => 'COOL-DOWN',
    Phase.none => 'INTERVALS',
  };
}

/// "400 M", "1:00", "JOG" (A8 titles): a distance step says its distance,
/// a timed rep its length, a timed recovery its style.
String stepDetail(SessionStep st) {
  final work = st.kind == StepKind.work;
  return switch (st.target) {
    TargetKind.distance =>
      st.value >= 1000 && st.value % 1000 == 0
          ? '${st.value ~/ 1000} KM'
          : '${st.value} M',
    TargetKind.time when work => Fmt.recovery(st.value),
    TargetKind.time ||
    TargetKind.equalToPreviousWork => st.style.name.toUpperCase(),
  };
}

/// The record screen's delta vs the last lap / rep, as displayed: flat only
/// when the ROUNDED delta in the display unit is 0, shown as "±0 s" with no
/// glyph (the flat dash read as a minus). Otherwise the arrow and "N s", so
/// a 0.6 s/km difference never reads "±1 s".
({String text, DeltaDirection direction}) ghostDelta(
  double live,
  double last,
  Units units,
) {
  final n = Fmt.deltaSecondsVsLast(live, last, units);
  return n == 0
      ? (text: '±0 s', direction: DeltaDirection.flat)
      : (
          text: '${n.abs()} s',
          direction: n < 0 ? DeltaDirection.up : DeltaDirection.down,
        );
}

/// "Rep flagged" only means something inside a rep; elsewhere say what it is.
String gpsBannerCopy(RecordingSnapshot s) {
  if (s.showEndRep) return 'GPS lost. Tap END REP at the end of the rep.';
  if (s.phase == Phase.warmup && s.needsGps && s.gpsLost) {
    return 'Distance reps need GPS. Wait for a fix to start reps.';
  }
  if (!s.hadFix) return 'Waiting for GPS';
  if (s.phase == Phase.work) return 'GPS dropped, this rep is flagged';
  return 'GPS dropped';
}

String timerCaption(RecordingSnapshot s) {
  // Total time has its own large cell in the vitals row (tester 0.2).
  if (!s.isPreset) return 'this lap';
  return switch (s.phase) {
    Phase.warmup when s.spec?.warmupSeconds != null => 'warm-up left',
    Phase.warmup => 'warm up, then tap START REPS',
    Phase.work when s.distanceStep => 'to go',
    Phase.work => 'left in rep',
    Phase.recovery => 'to rep ${s.repIndex + 1}',
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

/// A small label over a 36 sp figure: the floor for every number on the
/// record screen (A8, "no number smaller than 36 sp").
class AuxFigure extends StatelessWidget {
  const AuxFigure({
    super.key,
    required this.label,
    required this.value,
    required this.labelColor,
    required this.valueColor,
  });
  final String label;
  final String value;
  final Color labelColor;
  final Color valueColor;

  static final TextStyle style = RunSoloType.display44.copyWith(fontSize: 36);

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: RunSoloType.micro11.copyWith(color: labelColor)),
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(
          value,
          softWrap: false,
          style: style.copyWith(color: valueColor),
        ),
      ),
    ],
  );
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
    // Short reps (plan §3.7, A8): HR lags a 30 s effort, so in a rep the
    // cell shows the rep's max instead of the live reading.
    final repMax =
        s.shortReps &&
        s.phase == Phase.work &&
        s.stepMaxHr != null &&
        s.hr != null;
    final hr = repMax ? s.stepMaxHr : s.hr;
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
              repMax ? 'REP MAX HR' : 'HEART RATE',
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
                      key: const ValueKey('vitals-hr-pct'),
                      softWrap: false,
                      overflow: TextOverflow.fade,
                      style: hr == null
                          ? RunSoloType.body15.copyWith(color: t.semWarn)
                          : AuxFigure.style.copyWith(color: secondary),
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
        if (runAverage == null)
          Text(
            'average from 20 m',
            style: RunSoloType.body15.copyWith(color: secondary),
          )
        else
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                'run average ',
                style: RunSoloType.body15.copyWith(color: secondary),
              ),
              Text(
                Fmt.pace(runAverage, units),
                key: const ValueKey('run-average'),
                style: AuxFigure.style.copyWith(color: t.inkPrimary),
              ),
              Text(
                ' /${units == Units.mi ? 'mi' : 'km'}',
                style: RunSoloType.body15.copyWith(color: secondary),
              ),
            ],
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
    final fixedWarmup =
        s.phase == Phase.warmup && s.spec?.warmupSeconds != null;
    final ms = s.timed || fixedWarmup
        ? ctl.displayRemainingMs
        : ctl.displayLapElapsedMs;
    final toGo = s.metresToGo;
    final target = s.currentStep?.value ?? 0;
    final total = !recovery
        ? 0
        : s.phaseDurationMs > 0
        ? s.phaseDurationMs
        : s.recoveryMs;
    // A distance step counts metres down (A8); the ring fills by distance.
    final progress = toGo != null
        ? (target == 0 ? 0.0 : 1 - toGo / target)
        : total == 0
        ? 0.0
        : 1 - ms / total;
    // Scales down only when the digits would not fit (hour-long runs,
    // narrow phones); the 120 px face is the normal case.
    final digits = FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(
        // A8: with no fix the metres never extrapolate; they read "--".
        toGo == null
            ? Fmt.clock(ms)
            : s.gpsLost
            ? '--'
            : metresText(toGo),
        key: const ValueKey('timer'),
        softWrap: false,
        style: (style ?? RunSoloType.timer120).copyWith(
          // A8 + founder rule: the biggest number is also the brightest. In
          // a rep the countdown (or metres to go) is secondary, so it is
          // muted; in a recovery it is the primary number, in Bone.
          color: s.phase == Phase.work || (toGo != null && s.gpsLost)
              ? secondary
              : t.inkPrimary,
        ),
        textAlign: TextAlign.center,
      ),
    );
    return Column(
      children: [
        if (recovery)
          CustomPaint(
            painter: _RecoveryRingPainter(
              progress: progress,
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
            // The biggest number in a rep; second to the countdown in a
            // recovery. The FittedBox only shrinks it for a wide value.
            style: primaryStyle(compact, secondary: s.phase == Phase.recovery)
                .copyWith(
                  color: s.phase == Phase.recovery ? secondary : t.inkPrimary,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ),
        Text(
          '$title /${units == Units.mi ? 'mi' : 'km'}',
          style: RunSoloType.label13.copyWith(color: secondary),
        ),
        // With no fix there is no live pace or distance to show here, and
        // the GPS banner (and END REP) need the room on a short phone.
        if (!s.showEndRep && !s.gpsLost) ...[
          SizedBox(height: compact ? Space.x8 : Space.x16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AuxFigure(
                      label: 'DISTANCE',
                      value: Fmt.distance(s.lapDistanceM, units),
                      labelColor: secondary,
                      valueColor: t.inkPrimary,
                    ),
                    if (s.lastRepPaceSecPerKm != null) ...[
                      const SizedBox(height: Space.x4),
                      AuxFigure(
                        label: 'LAST REP',
                        value: Fmt.pace(s.lastRepPaceSecPerKm, units),
                        labelColor: secondary,
                        valueColor: t.inkPrimary,
                      ),
                    ],
                  ],
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
      final g = ghostDelta(live, last, units);
      delta = g.text;
      direction = g.direction;
      // A1: Vermillion and Arc deltas are Bone with the arrow on a zone
      // background (Vermillion drops to 4.1:1 on Z3).
      deltaColor = onZone
          ? t.inkPrimary
          : switch (direction) {
              DeltaDirection.up => t.semFaster,
              DeltaDirection.down => t.semSlower,
              DeltaDirection.flat => t.semHolding,
            };
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
        if (!showGhost)
          Text(
            s.isPreset ? 'warm-up pace' : 'first lap',
            style: RunSoloType.body15.copyWith(color: deltaColor),
          )
        else
          // A8: no number on the record screen under 36 sp.
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                s.isPreset ? 'last rep ' : 'last lap ',
                style: RunSoloType.body15.copyWith(color: deltaColor),
              ),
              Text(
                Fmt.pace(last, units),
                key: const ValueKey('ghost-pace'),
                style: AuxFigure.style.copyWith(color: t.inkPrimary),
              ),
              if (direction != null && delta != null) ...[
                const SizedBox(width: Space.x12),
                // The glyph rides inside the text run, centred on the digits:
                // a bare glyph has no baseline, so a baseline Row pinned it
                // to the top and "holding" read as a floating bar.
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        if (direction != DeltaDirection.flat)
                          WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: Padding(
                              padding: const EdgeInsets.only(right: Space.x4),
                              child: DeltaGlyph(
                                direction: direction,
                                color: deltaColor,
                                size: 14,
                              ),
                            ),
                          ),
                        TextSpan(text: delta),
                      ],
                    ),
                    key: const ValueKey('ghost-delta'),
                    softWrap: false,
                    overflow: TextOverflow.fade,
                    style: AuxFigure.style.copyWith(color: deltaColor),
                  ),
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
/// Under the PAUSED card the phase timer and stats keep their space but
/// hide, so no number peeks out around (or under) the card; total time
/// stays readable in the vitals row.
class _PausedHidden extends StatelessWidget {
  const _PausedHidden({required this.paused, required this.child});
  final bool paused;
  final Widget child;

  @override
  Widget build(BuildContext context) => Visibility(
    visible: !paused,
    maintainSize: true,
    maintainAnimation: true,
    maintainState: true,
    child: child,
  );
}

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

/// Warm-up of a distance session without a fix (W3): START REPS stays off
/// until GPS is back, and says why.
class _WaitingForGps extends StatelessWidget {
  const _WaitingForGps({required this.height});
  final double height;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Semantics(
      button: true,
      enabled: false,
      label: 'Start reps. Waiting for GPS',
      child: Container(
        key: const ValueKey('start-reps-waiting'),
        height: height,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: t.bgRaised,
          borderRadius: BorderRadius.circular(Radii.lap),
          border: Border.all(color: t.semWarn, width: 2),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'START REPS',
              style: RunSoloType.display44.copyWith(color: t.inkSecondary),
            ),
            Text(
              'waiting for GPS',
              style: RunSoloType.body15.copyWith(color: t.semWarn),
            ),
          ],
        ),
      ),
    );
  }
}

/// K1: the timed 5 km event (one 5000 m step from START, auto-stop).
bool isEventRun(RecordingSnapshot s) =>
    s.spec?.templateId == engine.SessionSpec.parkrunId;

/// The last 400 m (A10.10): projected finish becomes the primary number.
bool eventLastStretch(RecordingSnapshot s) {
  final m = s.metresToGo;
  return m != null && m <= 400;
}

/// "2.58 km" to 1.00 km, then metres rounded down to 10 m (5 m under
/// 100 m), as the A8 distance countdown; miles mode "1.60 mi" to 0.10 mi.
String eventDistanceToGo(double metres, Units units) {
  if (units == Units.mi && metres >= 160.9344) {
    return '${(metres / 1609.344).toStringAsFixed(2)} mi';
  }
  if (units == Units.km && metres >= 1000) {
    return '${(metres / 1000).toStringAsFixed(2)} km';
  }
  final step = metres < 100 ? 5 : 10;
  return '${(metres ~/ step) * step} m';
}

/// Projected finish: step time ÷ distance run × 5000; null for the first
/// 200 m and without a good fix (A10.10: never extrapolated).
double? eventProjectedSeconds(RecordingSnapshot s, int stepElapsedMs) {
  final st = s.currentStep;
  final togo = s.metresToGo;
  if (st == null || togo == null || s.gpsLost || s.gpsWeak) return null;
  final run = st.value - togo;
  if (run < 200 || stepElapsedMs <= 0) return null;
  return stepElapsedMs / 1000 / run * st.value;
}

class EventBlock extends StatelessWidget {
  const EventBlock({
    super.key,
    required this.s,
    required this.ctl,
    required this.units,
    this.compact = false,
    this.reduced = false,
  });
  final RecordingSnapshot s;
  final RecordingController ctl;
  final Units units;
  final bool compact;
  final bool reduced;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final muted = s.zone > 0 ? HrZones.secondaryOnZone : t.inkSecondary;
    final togo = s.metresToGo;
    final projected = eventProjectedSeconds(s, ctl.displayLapElapsedMs);
    final last = eventLastStretch(s);
    final toGoText = togo == null || s.gpsLost
        ? '--'
        : eventDistanceToGo(togo, units);
    final finishText = projected == null
        ? '--'
        : Fmt.clock(projected.round() * 1000);
    Widget number(String key, String text, String label, {required bool big}) {
      final dashed = text == '--';
      return Column(
        key: ValueKey(key),
        mainAxisSize: MainAxisSize.min,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              text,
              softWrap: false,
              style: primaryStyle(
                compact,
                secondary: !big,
              ).copyWith(color: big && !dashed ? t.inkPrimary : muted),
            ),
          ),
          Text(label, style: RunSoloType.label13.copyWith(color: muted)),
        ],
      );
    }

    final toGo = number('event-to-go', toGoText, 'to go', big: !last);
    final finish = number('event-finish', finishText, 'on pace for', big: last);
    return AnimatedSwitcher(
      duration: reduced ? Duration.zero : const Duration(milliseconds: 240),
      child: Column(
        key: ValueKey(last),
        mainAxisSize: MainAxisSize.min,
        children: last
            ? [finish, SizedBox(height: compact ? Space.x8 : Space.x16), toGo]
            : [toGo, SizedBox(height: compact ? Space.x8 : Space.x16), finish],
      ),
    );
  }
}
