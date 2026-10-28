import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/event_names.dart';
import '../app/format.dart';
import '../app/routes.dart';
import '../app/services.dart';
import '../map/map_surface.dart' show usesTerrainMap;
import '../map/retrace_tracker.dart' show RetraceInput;
import '../platform/gateway.dart';
import '../state/history_store.dart' show runModeOf;
import '../state/inrun_moments.dart'
    show InrunMoment, InrunMomentKind, inLastStretch;
import '../state/next_step.dart';
import '../state/recording_controller.dart';
import '../state/true_pace_smoother.dart';
import '../state/voice_coach_plan.dart' show CoachTarget;
import '../theme/caps_text.dart';
import '../theme/grade_band.dart';
import '../theme/theme.dart';
import '../theme/zones.dart';
import '../widgets/compare_card.dart';
import '../widgets/delta_glyph.dart';
import '../widgets/gps_bar.dart';
import '../widgets/inrun_moment.dart';
import '../widgets/inrun_prompt.dart';
import '../widgets/lap_button.dart';
import '../widgets/odometer_distance.dart';
import '../widgets/pace_dial.dart';
import '../widgets/route_to_go.dart';
import '../widgets/start_readout.dart';
import '../widgets/target_band.dart';
import '../widgets/quest_done_toast.dart';
import '../widgets/trail_ghost.dart';
import '../widgets/zone_gauge.dart';
import '../widgets/zone_ladder.dart';
import 'live_map_view.dart';

/// Record screen (design brief §4.4, addendum A1/A2): three layouts on one
/// screen. 4x4 = countdown + LAP; Laps run = count-up + LAP; Free run = no
/// LAP, the 200 dp go to time / distance / pace / HR. The background follows
/// the HR zone from the engine tracker (400 ms crossfade, instant reduced;
/// never a black frame after a wake because the controller seeds the last
/// zone). Timer counts down in a timed phase, up otherwise. No animation
/// runs except M2 (LAP ring), M3 (rep-complete invert) and the zone fade.
/// HR loss keeps its last zone for the tracker's five-second dwell while the
/// header says RECONNECTING, then returns to the neutral background.
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

  /// The distance goal's target time as the Start card showed it, read once
  /// per run (it never moves mid-run: the run screen names what the runner
  /// signed up for, 27-Oct "couldn't tell what he was aiming for").
  int? _goalTargetMs;
  String? _goalTargetRun;

  int? _goalTargetFor(RecordingSnapshot s) {
    final key = s.runId ?? '';
    if (_goalTargetRun != key) {
      _goalTargetRun = key;
      _goalTargetMs = null;
    }
    // A null is not kept: a run restored after process death can open before
    // the index is prepared, and the target arrives a build later.
    if (_goalTargetMs == null) {
      final spec = s.spec;
      _goalTargetMs = spec == null
          ? null
          : _services?.live?.targetFor(spec)?.liveTargetMs;
    }
    // Ease off on a goal run: the runner let the target go on purpose, so the
    // screen stops naming it or any gap to it (28-Oct); the run's own
    // projected finish stays. Read every build: the choice comes mid-run.
    if (_ctl?.goalTargetOf(key)?.eased ?? false) return null;
    return _goalTargetMs;
  }

  /// LV2: ties the card (drawn on top of the screen) to the secondary
  /// number of whichever layout is showing.
  final LayerLink _cardLink = LayerLink();

  /// The compare card's slot on the map page: page 1 has its own link, so
  /// the two pages never share one while a swipe has both built.
  final LayerLink _mapCardLink = LayerLink();

  /// Whether the last flood carried ink (true) or Bone (false) foreground.
  /// A change between the two switches the flood at once: the foreground
  /// flips instantly, and a fade between a Bone and an ink flood passes
  /// through colours neither reads on (about 3:1 at the midpoint).
  bool? _lastFloodInk;

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
    _ctl!.moment.addListener(_onMoment);
    _ctl!.attach();
    // A screen recreated mid-run (or opened on a run with a saved MAP
    // choice) fills the route from native once; events keep it current.
    if (_services!.maps.available) unawaited(_ctl!.syncRoute());
    _applyKeepScreenOn();
    _clock = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted && _ctl!.snapshot.recording) setState(() {});
    });
  }

  /// The run this screen watched while it was live (auto-stop hand-off).
  String? _liveRunId;

  /// The quest toast: shown once per quest id for 4 s. A quest already done
  /// when this screen first sees the run (the screen was recreated mid-run)
  /// is not toasted again.
  String? _questToast;
  String? _questToastedId;
  bool _questSeen = false;
  Timer? _questTimer;

  void _questToastCheck(RecordingSnapshot s) {
    if (s.runId == null) return;
    final id = s.questDoneId;
    if (!_questSeen) {
      _questSeen = true;
      _questToastedId = id;
      return;
    }
    if (id == null || id == _questToastedId) return;
    _questToastedId = id;
    final active = _services?.quests.state.active;
    final title = active != null && active.id == id ? active.title : null;
    _questQueued = title == null ? 'QUEST DONE' : 'QUEST DONE · $title';
    _showQueuedQuest();
  }

  /// A route cue outranks every moment but the goal's (24-Oct review #2): a
  /// moment due (or still up) while one shows is dropped, never queued
  /// behind a cue that can last a minute. The voice still says the km.
  void _onMoment() {
    final ctl = _ctl!;
    final m = ctl.moment.value;
    if (m != null &&
        m.kind != InrunMomentKind.goalReached &&
        routeCueShowing(ctl.snapshot)) {
      ctl.moment.value = null;
      return; // that set calls back here with null
    }
    if (m == null) _showQueuedQuest();
  }

  /// A quest done under an in-run moment waits for the moment to go, so its
  /// toast is never hidden under the moment's scrim (24-Oct review #8).
  String? _questQueued;

  void _showQueuedQuest() {
    final q = _questQueued;
    if (q == null || !mounted || _ctl?.moment.value != null) return;
    _questQueued = null;
    _questTimer?.cancel();
    setState(() => _questToast = q);
    _questTimer = Timer(QuestDoneToast.shownFor, () {
      if (mounted) setState(() => _questToast = null);
    });
  }

  /// Auto-stop (#53 review P3): only the recorder's own finalising → idle
  /// hands off, never another route to idle.
  bool _sawFinalising = false;

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

  PageController? _pageCtl;

  /// The map's rectangle, for the swipe-back outside it.
  final GlobalKey _mapBoxKey = GlobalKey(debugLabel: 'live-map-box');
  int _page = 0;

  /// The page the runner settled on, remembered for this run type (the
  /// setting is the old NUMBERS / MAP choice, so nothing new to store).
  void _onPage(String runType, int page) {
    if (page == _page) return;
    setState(() => _page = page);
    final types = _services!.settings.settings.liveMapTypes;
    if (types.contains(runType) == (page == 1)) return;
    unawaited(
      _services!.settings.update(
        (st) => st.copyWith(
          liveMapTypes: page == 1
              ? {...st.liveMapTypes, runType}
              : ({...st.liveMapTypes}..remove(runType)),
        ),
      ),
    );
    if (page == 1) unawaited(_ctl!.syncRoute());
  }

  void _goPage(int page) {
    final c = _pageCtl;
    if (c == null || !c.hasClients) return;
    unawaited(
      c.animateToPage(
        page,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  /// The service discarded the run (`FaultKind.startFailed`): nothing to
  /// save, back to Start with the message.
  /// The heat slowdown at the start of this run (from its first fix), for
  /// the live true pace; null until fetched, and when it never is (setting
  /// off, offline). One request per run, never retried mid-run.
  double? _startSlowdown;
  String? _slowdownRun;

  void _maybeFetchStartHeat(RecordingSnapshot s) {
    final run = s.runId;
    if (run == null || _slowdownRun == run) return;
    final first = _ctl!.liveRoute.points.firstOrNull;
    final weather = _services?.weather;
    if (first == null || weather == null) return;
    _slowdownRun = run;
    _startSlowdown = null;
    weather
        .slowdownAt(first.lat, first.lon)
        .then((v) {
          if (mounted && _slowdownRun == run) {
            setState(() => _startSlowdown = v);
            // The voice coach judges the same True Pace the dial shows.
            unawaited(_services?.recorder.setCoachSlowdown(v));
          }
        })
        .catchError((Object _) {});
  }

  /// The target band's marker: the live True Pace smoothed over ~30 s, reset
  /// at each rep or segment like the coach's. Only runs with a target.
  final TruePaceSmoother _smoother = TruePaceSmoother();
  Object? _segment;

  void _sampleTruePace(RecordingSnapshot s) {
    final ctl = _ctl!;
    if (ctl.coachTarget == null) return;
    final segment = (s.runId, s.phase, s.stepIndex);
    if (segment != _segment) {
      _segment = segment;
      _smoother.reset();
    }
    if (!s.recording) return;
    _smoother.add(
      ctl.now(),
      engine.RunTruePace.live(
        paceSecPerKm: s.livePaceSecPerKm,
        gradePct: s.gradePct,
        slowdown: _startSlowdown,
        distanceM: s.totalDistanceM,
      ),
    );
  }

  void _onSnapshot() {
    final s = _ctl!.snapshot;
    _ctl!.momentUnits = _services!.settings.settings.units;
    _onMoment();
    _questToastCheck(s);
    _sampleTruePace(s);
    if (s.active &&
        (runModeOf(s.mode).showsLiveTruePace || _ctl!.coachTarget != null)) {
      _maybeFetchStartHeat(s);
    }
    _applyKeepScreenOn();
    // #90: the paused notification's "tap to finish" lands on the finish
    // screen directly.
    if (_ctl!.takeFinishRequest() && mounted) unawaited(_tapStop());
    if (s.active && s.runId != null) _liveRunId = s.runId;
    if (s.state == RecorderState.finalising) _sawFinalising = true;
    // Auto-stop (K1 event at 5.00 km, plan §3.6): native ends the run on
    // its own; straight to the result, as after SAVE.
    final auto = _liveRunId;
    if (auto != null &&
        _sawFinalising &&
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

  /// Ricki 26-Sep: one tap on STOP ends the clock there (the recorder
  /// pauses, so the time and distance stop at the tap), then the finish
  /// screen asks SAVE, RESUME or DISCARD.
  bool _finishing = false;

  /// TOTAL where the run will end: the start of the pause STOP made, or of
  /// the pause it was tapped in (#88 ends a run stopped while paused there;
  /// #89 review P1). Null when the recorder did not pause: the finish
  /// screen then shows the live clock, since SAVE ends the run at SAVE.
  int? _stoppedAtMs;

  /// Bronco (manual sets, founder 28-Sep): every tap is one 240 m set;
  /// the [engine.SessionSpec.broncoSets]-th tap also pauses into the
  /// finish flow, so the test ends itself exactly on the last set.
  Future<void> _broncoLap(RecordingController ctl) async {
    await ctl.lap();
    if (!mounted) return;
    if (ctl.snapshot.lapIndex >= engine.SessionSpec.broncoSets) {
      await _tapStop();
    }
  }

  Future<void> _tapStop() async {
    if (_finishing || _stopping) return;
    final ctl = _ctl!;
    setState(() {
      _finishing = true;
      _stoppedAtMs = ctl.pausedAtElapsedMs;
    });
    // An auto-pause counts too: PAUSE on top of it makes it the runner's, so
    // the runner moving again cannot resume the recorder under the finish
    // screen. The run still ends where the auto-pause began.
    if (ctl.snapshot.recording || ctl.snapshot.autoPaused) {
      try {
        await ctl.pause();
        if (mounted) setState(() => _stoppedAtMs = ctl.pausedAtElapsedMs);
      } catch (_) {
        // Still recording: SAVE ends it all the same, at SAVE.
        if (mounted) setState(() => _stoppedAtMs = null);
      }
    } else {
      _stoppedAtMs ??= ctl.displayElapsedMs;
    }
  }

  Future<void> _resumeFromFinish() async {
    setState(() => _finishing = false);
    await _ctl!.resume();
  }

  /// DISCARD after its confirm: the recorder drops the live run (no run
  /// file, journal deleted); back to where the run was started from.
  Future<void> _discard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard this run?'),
        content: const Text("It won't be saved. This can't be undone."),
        actions: [
          TextButton(
            key: const ValueKey('discard-keep'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('KEEP'),
          ),
          TextButton(
            key: const ValueKey('discard-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('DISCARD'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _stopping = true);
    try {
      await _ctl!.discard();
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() {
          _stopping = false;
          _stopError = 'Could not discard right now. Try again.';
        });
      }
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
          // The service still holds the run (the journal is intact), so
          // SAVE again retries; recovery only lists runs that are not live.
          _stopError = 'Could not save right now. Tap SAVE again.';
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
    _ctl?.moment.removeListener(_onMoment);
    _clock?.cancel();
    _ctl?.repCompletePulse.removeListener(_onRepComplete);
    _ctl?.repStartPulse.removeListener(_onRepStart);
    _invert.dispose();
    _questTimer?.cancel();
    _pageCtl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t0 = Theme.of(context).extension<RunSoloTokens>()!;
    final ctl = _ctl!;
    final services = AppServices.of(context);
    final settings = services.settings.settings;
    final maxHr = services.maxHr.maxHr;
    final reduced = _reduced;
    return PopScope(
      canPop: false,
      // Android gesture navigation: a swipe in from the left edge IS the
      // system back gesture, so it never reaches the page-2 edge strip. On
      // the map page it goes back to the numbers; the run itself is never
      // popped (14-Oct).
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _page == 1 && _pageCtl != null) _goPage(0);
      },
      child: ListenableBuilder(
        listenable: ctl,
        builder: (context, _) {
          final s = ctl.snapshot;
          // What the screen is flooded with and the foreground that reads on
          // it: the zone's fill, or the run type's colour with no HR (D3).
          final flood = RunFlood.of(s.zone, liveRunTypeColor(liveRunType(s)));
          final zoneBg = flood.background;
          // Same-family fades (Bone to Bone, ink to ink) stay >= 7:1 at every
          // frame; crossing families is instant so no frame is unreadable.
          final crossesFamily =
              _lastFloodInk != null && _lastFloodInk != flood.ink;
          _lastFloodInk = flood.ink;
          final t = flood.tokens(t0);
          final baseTheme = Theme.of(context);
          final floodTheme = baseTheme.copyWith(
            extensions: [
              for (final e in baseTheme.extensions.values)
                if (e is! RunSoloTokens) e,
              t,
            ],
          );
          // No strap, no zone ladder (D3): its gutter goes back to the screen.
          // A paired strap reserves the gutter from the first frame, so the
          // figures don't shift ~15 dp when the first HR arrives (26-Oct).
          final ladderShown = (s.hr != null && s.zone > 0) || s.hrPaired;
          final rightGutter = ladderShown
              ? ZoneLadder.reserve
              : Space.recordGutter;
          final compact = MediaQuery.sizeOf(context).height < 720;
          // 148 on short screens: the 36 sp last-lap line (A8) needs the room.
          final lapHeight = compact ? 148.0 : 200.0;
          // LV2 (A10.1): the live compare card, in the secondary slot of
          // whichever layout is showing.
          final cardEnabled =
              settings.showWhileRunning &&
              compareCardAllowed(s, ctl.displayRemainingMs);
          // While the card shows, the recovery average's label under it is
          // hidden too, so no half line peeks out (A10.1: covered = hidden).
          final shown = ctl.lastCompare.value;
          final shownAt = ctl.lastCompareAt;
          // The last branch of the layout chain below: Free and Trail.
          final freeBlock =
              !((isEventRun(s) || s.isGoal) && s.phase == Phase.work) &&
              !(s.isGoal && s.phase == Phase.cooldown) &&
              !s.isPreset &&
              !s.isCooper &&
              !s.lapsEnabled;
          final cardShowing =
              cardEnabled &&
              shown != null &&
              shown.overlay &&
              shownAt != null &&
              ctl.now().difference(shownAt) < CompareCardHost.shown;
          final card = CompareCardHost(
            key: const ValueKey('compare-host'),
            events: ctl.lastCompare,
            receivedAt: () => ctl.lastCompareAt,
            now: ctl.now,
            enabled: cardEnabled,
            compact: compact,
            reduced: reduced,
            units: settings.units,
            targetM: isEventRun(s) ? s.currentStep?.value.toDouble() : null,
            backdrop: zoneBg,
          );
          // MAP view (founder 2-Oct): only where a map can show, remembered
          // per run type, and never under the finish or saving screens.
          final runType = liveRunType(s);
          final canMap = services.maps.available;
          // Run pages (11-Oct): page 1 the numbers, page 2 the map and the
          // route readouts; the page is remembered per run type.
          if (!(s.paused && !_finishing)) {
            _pageCtl ??= PageController(
              initialPage: _page = settings.liveMapTypes.contains(runType)
                  ? 1
                  : 0,
            );
          } else if (_pageCtl != null) {
            final old = _pageCtl!;
            _pageCtl = null;
            WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
          }
          // In MAP the numbers' leftover space belongs to the map.
          // Free / Trail have no LAP button: their block takes that room.
          final pausedNow = s.paused && !_finishing;
          // The coach layer (sessions with a target): the target band while a
          // rep or goal is on, and the next-step line, worded like the voice.
          // Metric labels: 17 sp, one step down in a structured session
          // (its coach layer needs the room), and no step up on a short
          // phone there (the 4x4 layout has none to spare).
          final labelSize = s.isPreset
              ? RunLabelScope.floor
              : RunLabelScope.defaultSize;
          final coach = pausedNow || _finishing
              ? null
              : _CoachLayer.of(
                  s: s,
                  ctl: ctl,
                  smoothed: _smoother.value(ctl.now()),
                  units: settings.units,
                  labelColor: t.inkSecondary,
                  textColor: t.inkPrimary,
                  labelSize: labelSize,
                );
          final waitGps =
              (s.isPreset || s.isCooper) &&
              s.phase == Phase.warmup &&
              (s.needsGps || s.isCooper) &&
              s.gpsLost;
          final lapGap =
              !pausedNow &&
              !waitGps &&
              !(s.isCooper && s.phase == Phase.warmup) &&
              (s.isCooper ||
                  (s.isPreset && !(s.phase == Phase.warmup || s.showEndRep)) ||
                  (!s.isPreset && !s.lapsEnabled));
          const Widget gap = SizedBox.shrink();
          // Page 2: the map and every route readout (none of it is on page 1).
          final route = s.route;
          final retraceSt = s.retrace;
          final showStart =
              runModeOf(s.mode).showsElevation &&
              (retraceSt.heightVsStartM != null || retraceSt.headingBack);
          final readouts = <Widget>[
            // Page 2 top: the trail gap to best, one line (page 1 has both).
            if (s.trail case final tr?)
              TrailGhostReadout(trail: tr, compact: true, page2: true),
            if (runModeOf(s.mode).showsElevation && s.elevGainM != null)
              ElevationRow(
                s: s,
                units: settings.units,
                labelColor: t.inkSecondary,
                valueColor: t.inkPrimary,
                showGrade: !compact,
              ),
            if (showStart)
              StartReadout(
                heightVsStartM: retraceSt.heightVsStartM,
                backToStartM: retraceSt.headingBack
                    ? retraceSt.backToStartM
                    : null,
                units: settings.units,
                labelColor: t.inkSecondary,
                valueColor: t.inkPrimary,
              ),
            if (route != null)
              RouteToGoRow(
                route: route,
                units: settings.units,
                labelColor: t.inkSecondary,
                valueColor: t.inkPrimary,
                warnColor: t.semWarn,
              ),
          ];
          final hasPage2 = canMap || readouts.isNotEmpty;
          final Widget page2 = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The compare card's slot: it slides in over the top of the map.
              CompareSlot(
                link: _mapCardLink,
                child: const SizedBox(width: double.infinity, height: 0),
              ),
              Expanded(
                child: canMap && !_finishing && !_stopping
                    ? LiveMapView(
                        mapBoxKey: _mapBoxKey,
                        maps: services.maps,
                        track: ctl.liveRoute,
                        typeColor: liveRunTypeColor(runType),
                        readouts: readouts,
                        // A short phone with the big LAP button leaves the
                        // map under ~100 dp: numbers only there. A 4x4 has
                        // no LAP button, so its map keeps the room.
                        hideMap: compact && s.lapsEnabled && !s.isPreset,
                        numbers: EqualFigures(
                          figures: runSoFarFigures(s, ctl, settings.units),
                          valueKeys: const [
                            ValueKey('map-page-distance'),
                            ValueKey('map-page-time'),
                            ValueKey('map-page-pace'),
                          ],
                          cap: compact ? 52 : 64,
                          labelColor: t.inkSecondary,
                          valueColor: t.inkPrimary,
                        ),
                        plan: ctl.followedPlan,
                        terrain: usesTerrainMap(s.mode),
                        retrace: RetraceInput(
                          retracing: s.retrace.retracing,
                          same: s.retrace.same,
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final r in readouts) ...[
                            r,
                            const SizedBox(height: Space.x8),
                          ],
                        ],
                      ),
              ),
              if (_page == 1 && hasPage2) ...[
                const SizedBox(height: Space.x8),
                PageSwitchButton.numbers(onTap: () => _goPage(0)),
              ],
              if (coach != null && !freeBlock) ...[
                const SizedBox(height: Space.x8),
                coach,
              ],
              if (!s.showEndRep) ...[
                const SizedBox(height: Space.x8),
                GpsBar(accuracyM: s.gpsAccuracyM, lost: s.gpsLost),
              ],
            ],
          );
          final page1 = <Widget>[
            // The Free / Trail block takes the room itself.
            if (!freeBlock) const Spacer(),
            if ((isEventRun(s) || s.isGoal) && s.phase == Phase.work) ...[
              // K1 / A10.10, G3 (A8): distance or time to go is
              // the biggest number, projected finish second;
              // they never swap: the last 400 m / last minute only tints
              // the to-go figure.
              _PausedHidden(
                paused: s.paused,
                child: EventBlock(
                  s: s,
                  ctl: ctl,
                  units: settings.units,
                  compact: compact,
                  reduced: reduced,
                  card: _cardLink,
                  targetMs: s.isGoal ? _goalTargetFor(s) : null,
                ),
              ),
              // 29-Sep field test: the run's own numbers under
              // the countdown (big screens only; compact keeps
              // the two-number budget).
              if (!compact) ...[
                const SizedBox(height: Space.x16),
                _PausedHidden(
                  paused: s.paused,
                  child: _EventStats(s: s, ctl: ctl, units: settings.units),
                ),
              ],
              _CoachSlot(coach),
            ] else if (s.isGoal && s.phase == Phase.cooldown) ...[
              // G3: after the goal, the cool-down's time is
              // primary and the goal's result sits locked below.
              _PausedHidden(
                paused: s.paused,
                child: GoalDoneBlock(
                  s: s,
                  ctl: ctl,
                  units: settings.units,
                  compact: compact,
                  targetMs: _goalTargetFor(s),
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
                  hideCaption:
                      compact &&
                      coach != null &&
                      coach.nextLine != null &&
                      (s.phase == Phase.work || s.phase == Phase.recovery),
                  style: switch (s.phase) {
                    Phase.work => primaryStyle(compact, secondary: true),
                    Phase.recovery => primaryStyle(compact),
                    _ => null,
                  },
                ),
              ),
              _CoachSlot(coach),
              CompareSlot(
                link: s.phase == Phase.warmup ? null : _cardLink,
                child: Visibility(
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
                          hideAverage: cardShowing,
                        ),
                ),
              ),
            ] else if (s.isCooper) ...[
              // Scales down rather than overflow when a banner
              // and the GPS wait share a short screen with it;
              // the high flex keeps it at full size otherwise
              // (the spacers around it share what is left), and
              // Expanded keeps Pause / Stop at the bottom.
              Expanded(
                flex: 20,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: _PausedHidden(
                    paused: s.paused,
                    child: _CooperBlock(
                      s: s,
                      ctl: ctl,
                      units: settings.units,
                      compact: compact,
                      card: _cardLink,
                    ),
                  ),
                ),
              ),
            ] else if (s.lapsEnabled) ...[
              _PausedHidden(
                paused: s.paused,
                child: _TimerBlock(s: s, ctl: ctl),
              ),
              _CoachSlot(coach),
              // The PAUSED card sits here; keep the space, hide
              // the numbers so nothing peeks out around it.
              CompareSlot(
                link: _cardLink,
                child: Visibility(
                  visible: !s.paused,
                  maintainSize: true,
                  maintainAnimation: true,
                  maintainState: true,
                  child: _Stats(s: s, units: settings.units),
                ),
              ),
            ] else ...[
              // The big gap to your best on a known trail; absent (no gap)
              // until one is matched.
              _FreeRunBlock(
                s: s,
                ctl: ctl,
                units: settings.units,
                maxHr: maxHr,
                compact: compact,
                card: _cardLink,
                reserveCard: settings.showWhileRunning && s.tipsMuted != true,
                cardShowing: cardShowing,
                trail: s.trail,
              ),
            ],
            // Page 1's way to the map, matching NUMBERS on page 2. Not in a
            // structured session: its 4x4 layout has no 60 dp to spare (the
            // dots and the swipe still work there). Nor on a short phone with
            // the big LAP button: the 60 dp overflowed page 1 by ~30 px.
            if (canMap && !s.isPreset && !(compact && s.lapsEnabled)) ...[
              SizedBox(height: compact ? Space.x4 : Space.x8),
              PageSwitchButton.map(onTap: () => _goPage(1)),
            ],
            // END REP: the banner already says GPS is lost,
            // and the short phone needs the bar's height.
            if (!s.showEndRep) ...[
              SizedBox(height: compact ? Space.x4 : Space.x8),
              Visibility(
                visible: !s.paused,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: GpsBar(accuracyM: s.gpsAccuracyM, lost: s.gpsLost),
              ),
            ],
            if (lapGap && !freeBlock) const Spacer(),
          ];
          final scaffold = Scaffold(
            backgroundColor: Colors.transparent,
            body: Stack(
              fit: StackFit.expand,
              children: [
                // Aurora: 400 ms zone crossfade, final state directly when
                // motion is reduced. HR loss stays in its zone for five seconds with
                // RECONNECTING, then the engine sends zone 0 (neutral).
                AnimatedContainer(
                  key: const ValueKey('zone-background'),
                  duration: reduced || crossesFamily
                      ? Duration.zero
                      : MotionDurations.zoneCrossfade,
                  curve: MotionCurves.standard,
                  color: zoneBg,
                ),
                SafeArea(
                  child: Padding(
                    // The right edge belongs to the zone ladder.
                    padding: EdgeInsets.only(
                      left: Space.recordGutter,
                      right: rightGutter,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(height: compact ? Space.x4 : Space.x8),
                        _Header(
                          s: s,
                          maxHr: maxHr,
                          compact: compact,
                          trailing: hasPage2 && !pausedNow
                              ? PageDots(page: _page, onTap: (p) => _goPage(p))
                              : null,
                        ),
                        if (_stopError != null)
                          _Banner(text: _stopError!, color: t.semDanger)
                        else if (s.fault != null)
                          _Banner(text: s.fault!, color: t.semDanger)
                        else if (s.gpsLost || s.showEndRep)
                          _Banner(text: gpsBannerCopy(s), color: t.semWarn)
                        else if (s.notice != null)
                          _Banner(text: s.notice!, color: t.semWarn),
                        if (_questToast case final q? when !pausedNow)
                          QuestDoneToast(
                            text: q,
                            fill: t.inkPrimary,
                            ink: t.bgBase,
                            compact: compact,
                          ),
                        // Route cues are loud (24-Oct review #2): amber on
                        // the near-black plate, the same on every flood.
                        if (s.trail?.turnCue == true && !pausedNow)
                          TrailTurnCard(
                            fill: NightSession.bgBase,
                            ink: NightSession.semWarn,
                            compact: compact,
                          ),
                        if (route?.endCue != null && !pausedNow)
                          RouteEndCard(
                            cue: route!.endCue!,
                            fill: NightSession.bgBase,
                            ink: NightSession.semWarn,
                            compact: compact,
                          ),
                        // The map page says OFF ROUTE in its to-go row.
                        if (route != null &&
                            route.endCue == null &&
                            route.off &&
                            !(hasPage2 && _page == 1) &&
                            !pausedNow)
                          RouteEndCard.off(
                            fill: NightSession.bgBase,
                            ink: NightSession.semWarn,
                            compact: compact,
                          ),
                        if (pausedNow) ...[
                          // O7: run so far, big, and one big RESUME. No LAP.
                          Expanded(
                            child: _PausedPanel(
                              figures: runSoFarFigures(s, ctl, settings.units),
                              onResume: ctl.resume,
                              auto: s.autoPaused,
                              note: s.isCooper && s.phase == Phase.work
                                  ? kCooperPausedNote
                                  : (s.autoPaused ? kAutoPausedNote : null),
                              compact: compact,
                              secondary: t.inkSecondary,
                            ),
                          ),
                          if (!s.showEndRep) ...[
                            const SizedBox(height: Space.x12),
                            GpsBar(accuracyM: s.gpsAccuracyM, lost: s.gpsLost),
                          ],
                        ] else
                          Expanded(
                            child: _RunPages(
                              key: const ValueKey('run-pages'),
                              controller: _pageCtl!,
                              twoPages: hasPage2,
                              onPage: (p) => _onPage(runType, p),
                              one: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: page1,
                              ),
                              two: page2,
                            ),
                          ),
                        if (coach != null && freeBlock && !pausedNow) ...[
                          const SizedBox(height: Space.x8),
                          coach,
                        ],
                        SizedBox(height: compact ? Space.x4 : Space.x8),
                        if (pausedNow)
                          const SizedBox.shrink()
                        else if ((s.isPreset || s.isCooper) &&
                            s.phase == Phase.warmup &&
                            (s.needsGps || s.isCooper) &&
                            s.gpsLost)
                          // W3: distance reps cannot end without GPS, so
                          // the start waits for a fix. The wait keeps the
                          // session's own label (field test 27-Sep): the
                          // test's said BEGIN REPS.
                          _WaitingForGps(
                            height: lapHeight,
                            label: s.isCooper ? 'BEGIN TEST' : 'BEGIN REPS',
                          )
                        else if (s.isCooper && s.phase == Phase.warmup)
                          // A5: the LAP button's slot; its own action,
                          // not a lap.
                          LapButton(
                            key: const ValueKey('start-test'),
                            label: 'BEGIN TEST',
                            onLap: ctl.startReps,
                            pulse: ctl.lapPulse,
                            haptics: settings.haptics,
                            height: lapHeight,
                          )
                        else if (s.isCooper)
                          // No LAP anywhere for the 12 minutes (A5): nothing
                          // can end the test early.
                          gap
                        else if (s.isPreset && s.phase == Phase.warmup)
                          LapButton(
                            key: const ValueKey('start-reps'),
                            label: 'BEGIN REPS',
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
                          gap
                        else if (s.lapsEnabled)
                          LapButton(
                            onLap: s.bronco ? () => _broncoLap(ctl) : ctl.lap,
                            pulse: ctl.lapPulse,
                            haptics: settings.haptics,
                            height: lapHeight,
                          )
                        else
                          gap,
                        const SizedBox(height: Space.x12),
                        Row(
                          children: [
                            // LV2: in the control row, where it costs no
                            // height and squeezes no number (#77 goldens).
                            if (s.tipsMuted == false) ...[
                              MuteTipsButton(onTap: ctl.muteTips),
                              const SizedBox(width: Space.x12),
                            ],
                            // Paused: RESUME is the big button above, so
                            // the row is STOP alone.
                            if (!pausedNow) ...[
                              Expanded(
                                child: _PauseButton(
                                  paused: s.paused,
                                  onTap: s.paused ? ctl.resume : ctl.pause,
                                ),
                              ),
                              const SizedBox(width: Space.x12),
                            ],
                            Expanded(child: _StopButton(onTap: _tapStop)),
                          ],
                        ),
                        // A5: pausing is allowed, but it ends the test.
                        if (s.isCooper && s.phase == Phase.work && !s.paused)
                          Padding(
                            padding: const EdgeInsets.only(top: Space.x8),
                            child: Text(
                              kCooperPauseWarning,
                              key: const ValueKey('cooper-pause-warning'),
                              textAlign: TextAlign.center,
                              style: RunSoloType.runCaption.copyWith(
                                color: t.inkSecondary,
                              ),
                            ),
                          ),
                        const SizedBox(height: Space.x16),
                      ],
                    ),
                  ),
                ),
                // Full Instrument: the zone ladder on the right edge, from
                // under the status bar to above the control row. Hidden with
                // no HR.
                Positioned(
                  right: 0,
                  top: MediaQuery.paddingOf(context).top + Space.x12,
                  bottom:
                      MediaQuery.paddingOf(context).bottom +
                      Space.x16 +
                      56 +
                      Space.x12,
                  width: ZoneLadder.width + ZoneLadder.pointer,
                  child: ZoneLadder(
                    zone: s.hr == null ? 0 : s.zone,
                    position: s.zonePosition,
                  ),
                ),
                CompareCardLayer(
                  link: _page == 1 ? _mapCardLink : _cardLink,
                  width:
                      MediaQuery.sizeOf(context).width -
                      Space.recordGutter -
                      rightGutter,
                  anchorBottom: !s.isPreset && s.lapsEnabled,
                  card: card,
                ),
                // The in-run moment (km / mile, rep done, halfway, last
                // 400 m, goal reached): about 1.5 s, over the numbers, no
                // taps. Not on the finish screen or while paused.
                // A route cue (turn around, off route, route done) outranks
                // every moment but the goal's: the moment is dropped, so a
                // km mark never buries a turnaround (24-Oct review #2).
                ValueListenableBuilder<InrunMoment?>(
                  valueListenable: ctl.moment,
                  builder: (context, m, _) =>
                      m == null ||
                          pausedNow ||
                          _finishing ||
                          (routeCueShowing(s) &&
                              m.kind != InrunMomentKind.goalReached)
                      ? const SizedBox.shrink()
                      : InrunMomentOverlay(
                          key: ValueKey('inrun-moment-${m.serial}'),
                          moment: m,
                          accent: flood.background,
                          reduced: reduced,
                          onDone: () {
                            if (ctl.moment.value?.serial == m.serial) {
                              ctl.moment.value = null;
                            }
                          },
                        ),
                ),
                // The mid-run two-button coach prompt (last 2 km, between reps,
                // well ahead, falling behind): over everything, takes taps,
                // gone when answered or after its 8 s. Stays up while paused
                // (a runner at the lights can tap; the window waits); not on
                // the finish screen.
                ValueListenableBuilder<PromptEvent?>(
                  valueListenable: ctl.prompt,
                  builder: (context, p, _) => p == null || _finishing
                      ? const SizedBox.shrink()
                      : InrunPromptOverlay(
                          key: ValueKey('inrun-prompt-overlay-${p.id}'),
                          prompt: p,
                          accent: flood.background,
                          reduced: reduced,
                          onChoose: ctl.answerPrompt,
                        ),
                ),
                if (_finishing)
                  // The finish and saving screens are their own dark ground:
                  // they keep the base theme, not the flood's.
                  Theme(
                    data: baseTheme,
                    child: _FinishScreen(
                      ctl: ctl,
                      elapsedMs: _stoppedAtMs,
                      units: settings.units,
                      error: _stopError,
                      onSave: _stop,
                      onResume: _resumeFromFinish,
                      onDiscard: _discard,
                    ),
                  ),
                IgnorePointer(
                  child: FadeTransition(
                    opacity: _invert,
                    child: ColoredBox(color: t0.inkPrimary),
                  ),
                ),
                if (_stopping)
                  ColoredBox(
                    color: t0.bgBase.withValues(alpha: 0.7),
                    child: Center(
                      child: Text(
                        'SAVING',
                        style: RunSoloType.title28.copyWith(
                          color: t0.inkSecondary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
          return Theme(data: floodTheme, child: scaffold.labelScope(labelSize));
        },
      ),
    );
  }
}

/// The run type the MAP / NUMBERS choice is remembered under: the chip the
/// runner picked (`free`, `trail`, `laps`, `intervals`, `goal`, `tests`).
String liveRunType(RecordingSnapshot s) {
  if (isEventRun(s) || s.isGoal) return 'goal';
  if (s.isCooper || s.bronco) return 'tests';
  return s.mode.name == 'cooper' ? 'tests' : s.mode.name;
}

/// A route cue is on the screen: TURN AROUND or ROUTE DONE at the end of a
/// followed route, off the route, or a known trail's turnaround.
bool routeCueShowing(RecordingSnapshot s) =>
    s.route?.endCue != null || s.route?.off == true || s.trail?.turnCue == true;

/// The run type's Aurora colour (the route on the map).
Color liveRunTypeColor(String type) => switch (type) {
  'laps' => AuroraRunType.laps,
  'intervals' => AuroraRunType.intervals,
  'goal' => AuroraRunType.goal,
  'tests' => AuroraRunType.tests,
  'trail' => AuroraRunType.trail,
  _ => AuroraRunType.free,
};

const String kCooperCooldownCaption = 'Cool down, then stop';

/// A4: with no fix the metres never extrapolate; they read "--".
String timerFigureText(RecordingSnapshot s, RecordingController ctl) {
  final toGo = s.metresToGo;
  if (toGo == null) return Fmt.clock(timerFigureMs(s, ctl));
  return s.gpsLost ? '--' : metresText(toGo);
}

/// The 4x4 / Laps timer's milliseconds: a timed phase (and a fixed warm-up)
/// counts down, anything else counts up through the lap.
int timerFigureMs(RecordingSnapshot s, RecordingController ctl) {
  final fixedWarmup = s.phase == Phase.warmup && s.spec?.warmupSeconds != null;
  return s.timed || fixedWarmup
      ? ctl.displayRemainingMs
      : ctl.displayLapElapsedMs;
}

/// The segment's average pace (sec/km), from 20 m.
double? segmentAverage(RecordingSnapshot s, RecordingController ctl) {
  final ms = ctl.displayLapElapsedMs;
  return s.lapDistanceM > 20 && ms > 0
      ? ms / 1000 / (s.lapDistanceM / 1000)
      : null;
}

/// The Free run's average pace (sec/km), from 20 m.
double? runAverageSecPerKm(RecordingSnapshot s, RecordingController ctl) {
  final ms = ctl.displayElapsedMs;
  return s.totalDistanceM > 20 && ms > 0
      ? ms / 1000 / (s.totalDistanceM / 1000)
      : null;
}

/// The 12-minute test's big clock and its caption.
(int, String) cooperClock(RecordingSnapshot s, RecordingController ctl) =>
    switch (s.phase) {
      Phase.work => (ctl.displayRemainingMs, 'left in the test'),
      Phase.cooldown => (ctl.displayLapElapsedMs, kCooperCooldownCaption),
      _ => (ctl.displayElapsedMs, 'warm up, then tap BEGIN TEST'),
    };

/// A target time on the clock, rounded to the second like the Start card's
/// line ([Prediction.clock]), so the two never disagree by one.
String _targetClock(int ms) => Fmt.clock((ms / 1000).round() * 1000);

/// The event / goal "to go" figure (distance, or time for a time goal).
String eventToGoText(
  RecordingSnapshot s,
  RecordingController ctl,
  Units units,
) {
  final togo = s.metresToGo;
  if (s.distanceStep || togo != null) {
    return togo == null || s.gpsLost ? '--' : eventDistanceToGo(togo, units);
  }
  return Fmt.clock(ctl.displayRemainingMs + 999);
}

/// The to-go figure as the run starts (the goal distance or the full clock):
/// the widest form it takes, used to hold its block's width. Null before the
/// step is known.
String? eventStartText(RecordingSnapshot s, Units units) {
  final st = s.currentStep;
  if (st == null) return null;
  if (s.distanceStep || s.metresToGo != null) {
    return eventDistanceToGo(st.value.toDouble(), units);
  }
  return Fmt.clock((st.value * 1000).round());
}

/// The widest the projected figure gets, so its block holds its width from
/// the "--" before the first 200 m to the full projection.
String? eventFinishWidest(RecordingSnapshot s, Units units) {
  final st = s.currentStep;
  if (s.distanceStep || s.metresToGo != null) {
    return st != null && st.value >= 15000 ? '8:88:88' : '88:88';
  }
  return units == Units.mi ? '88.88 mi' : '88.88 km';
}

double _widestBlock(BuildContext context, TextStyle style, List<String> texts) {
  final scaler = MediaQuery.textScalerOf(context);
  var widest = 0.0;
  for (final text in texts) {
    final p = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    if (p.width > widest) widest = p.width;
    p.dispose();
  }
  return widest;
}

/// The event / goal "projected" figure (finish time, or distance for a
/// time goal).
String eventFinishText(
  RecordingSnapshot s,
  RecordingController ctl,
  Units units,
) {
  if (s.distanceStep || s.metresToGo != null) {
    final projected = eventProjectedSeconds(s, ctl.displayLapActiveMs);
    return projected == null ? '--' : Fmt.clock(projected.round() * 1000);
  }
  final projected = goalProjectedMetres(s, ctl.displayLapActiveMs);
  return projected == null ? '--' : goalDistanceText(projected, units);
}

/// What the projected figure is called: a distance step projects a finish
/// time, a time goal a distance. "On pace for" read backwards (S7).
String eventFinishLabel(RecordingSnapshot s) =>
    s.distanceStep || s.metresToGo != null
    ? 'projected finish'
    : 'projected distance';

/// The MAP view's hero: the dominant figure of the NUMBERS layout for this
/// phase, from the same helpers those blocks draw. Branch order mirrors the
/// record screen's layout chain, so every mode and phase agrees.
LiveHero liveHero(RecordingSnapshot s, RecordingController ctl, Units units) {
  final unit = units == Units.mi ? 'mi' : 'km';
  if ((isEventRun(s) || s.isGoal) && s.phase == Phase.work) {
    // To go leads for the whole run: the hero never swaps in the last stretch.
    return LiveHero(text: eventToGoText(s, ctl, units), label: 'to go');
  }
  if (s.isGoal && s.phase == Phase.cooldown) {
    return LiveHero(
      text: Fmt.clock(ctl.displayLapElapsedMs),
      label: 'cool-down',
    );
  }
  if (s.isPreset) {
    if (s.phase == Phase.work) {
      return LiveHero(
        text: Fmt.pace(segmentAverage(s, ctl), units),
        label: 'REP AVERAGE /$unit',
      );
    }
    return LiveHero(text: timerFigureText(s, ctl), label: timerCaption(s));
  }
  if (s.isCooper) {
    final (ms, caption) = cooperClock(s, ctl);
    return LiveHero(text: Fmt.clock(ms), label: caption);
  }
  if (s.lapsEnabled) {
    return LiveHero(text: timerFigureText(s, ctl), label: timerCaption(s));
  }
  // Free and Trail (founder 3-Oct, reversing 30-Sep): distance, time and
  // average pace are equal in size, distance first. NUMBERS and MAP both draw
  // these figures.
  final distance = Fmt.distance(s.totalDistanceM, units);
  return LiveHero(
    text: distance,
    label: 'DISTANCE',
    figures: [
      LiveFigure(label: 'DISTANCE', value: distance),
      LiveFigure(label: 'TIME', value: Fmt.clock(ctl.displayElapsedMs)),
      LiveFigure(
        label: 'AVG PACE /$unit',
        value: Fmt.pace(runAverageSecPerKm(s, ctl), units),
      ),
    ],
  );
}

/// Metres to go (A8): whole metres, rounded down to 5 m under 100 m and
/// to 10 m above; holds at "0 m" until the auto-lap sample lands.
String metresText(double metres) {
  final m = metres.floor();
  final r = m < 100 ? m - m % 5 : m - m % 10;
  return '$r m';
}

/// Where the live compare card may show (A10.1 "When it shows"): only while
/// recording, never with END REP, never in a rep or warm-up (it would cover
/// the primary), never in the last 10 s of a timed recovery, never in the
/// timed 5 km's last 400 m, and not once tips are muted for this run.
bool compareCardAllowed(RecordingSnapshot s, int remainingMs) {
  if (s.tipsMuted == true || !s.recording || s.showEndRep) return false;
  // The timed 5 km and a GOAL (G3) share the event layout: the card covers
  // the projected finish, never in the last 400 m / last minute.
  if (isEventRun(s) || (s.isGoal && s.phase == Phase.work)) {
    return s.phase == Phase.work && !eventLastStretch(s);
  }
  if (s.isPreset) {
    return switch (s.phase) {
      Phase.recovery => s.distanceStep || remainingMs > 10000,
      Phase.cooldown => true,
      _ => false,
    };
  }
  return true;
}

/// Size of a 4x4 timed phase's two big numbers: the primary (rep average in
/// a rep, countdown in a recovery) and the secondary one. Short screens
/// (< 720 dp) step both down.
TextStyle primaryStyle(bool compact, {bool secondary = false}) => secondary
    ? (compact ? RunSoloType.display64 : RunSoloType.display96)
    : RunSoloType.timer120.copyWith(
        fontSize: RunSoloType.runSize(compact ? 128 : 168),
      );

/// The to-go figure's last-stretch emphasis colour: the arc accent where it
/// holds 3:1 (large figures) on the zone's flood, else its deeper day
/// variant, else plain ink. Never a size or position change.
Color lastStretchAccent(RunSoloTokens t, int zone) {
  final fill = HrZones.background(zone);
  for (final c in [t.accentArc, NightSessionLight.accentArc]) {
    if (HrZones.contrast(c, fill) >= 3) return c;
  }
  return t.inkPrimary;
}

/// Rep (a work step of a structured session) in the Intervals magenta,
/// recovery in mint; everything else Bone. The words stay too (colour is never
/// the only cue), and the countdown box keeps its outline. A hue that does not
/// read on the current zone fill falls back to Bone.
Color phaseTitleColor(RecordingSnapshot s, RunSoloTokens t) {
  if (s.mode != RecordMode.intervals || !s.isPreset) return t.inkPrimary;
  if (isEventRun(s) || s.isGoal) return t.inkPrimary;
  final hue = switch (s.phase) {
    Phase.work => AuroraRunType.intervals,
    Phase.recovery => t.semImproving,
    _ => null,
  };
  // The mint recovery title stays on Z1/Z2 (and no zone); on Z3-Z5 it is
  // Bone like the zone label (S2).
  if (hue == null) return t.inkPrimary;
  // On an ink flood (Z3, Z4, run-type) every foreground is ink (D1, D3).
  if (HrZones.isInk(t)) return t.inkPrimary;
  if (s.phase == Phase.recovery && s.zone >= HrZones.boneLabelsFrom) {
    return t.inkPrimary;
  }
  return HrZones.legibleOn(s.zone, hue, t.inkPrimary);
}

/// `repIndex` is 1-based in work / recovery (RecorderCore.kt); the last rep
/// goes straight to cool-down, so recoveries count to `reps - 1` (brief
/// §4.4 "Recovery 2 of 3").
String phaseTitle(RecordingSnapshot s) {
  switch (s.mode) {
    case RecordMode.laps:
      // Bronco (manual sets, founder 28-Sep): 5 taps, one per 240 m set.
      if (s.bronco) {
        final n = s.lapIndex + 1;
        return n >= engine.SessionSpec.broncoSets
            ? 'SET ${engine.SessionSpec.broncoSets} OF ${engine.SessionSpec.broncoSets}'
            : 'SET $n OF ${engine.SessionSpec.broncoSets}';
      }
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
    case RecordMode.trail:
      return 'TRAIL RUN';
    case RecordMode.cooper:
      return switch (s.phase) {
        Phase.warmup => 'WARM-UP',
        Phase.cooldown => 'COOL-DOWN',
        _ => '12-MINUTE TEST',
      };
    case RecordMode.intervals:
      break;
  }
  if (!s.isPreset) return 'LAP ${s.lapIndex + 1}';
  if (isEventRun(s) && s.phase == Phase.work) {
    final name = kEventNames.parkrun.toUpperCase();
    return '$name · 5 KM';
  }
  if (s.isGoal) {
    final name = (s.spec?.name ?? '').toUpperCase();
    if (s.phase == Phase.cooldown) return 'COOL-DOWN · $name DONE';
    if (s.phase == Phase.work) {
      return 'GOAL · $name';
    }
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

/// Under Pause during the 12-minute test (A5).
const String kCooperPauseWarning = 'Pausing ends the test';

/// Under AUTO-PAUSED: the recorder paused itself because you stopped.
const String kAutoPausedNote = 'You stopped. It resumes when you move.';

/// On the PAUSED card when the test was paused (A5: no estimate).
const String kCooperPausedNote =
    'The test ended when you paused, so this one gives no estimate.';

/// "Rep flagged" only means something inside a rep; elsewhere say what it is.
String gpsBannerCopy(RecordingSnapshot s) {
  if (s.showEndRep) return 'GPS lost. Tap END REP at the end of the rep.';
  if (s.isCooper && s.phase == Phase.warmup && s.gpsLost) {
    return 'The test needs GPS. Wait for a fix to start it.';
  }
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
    Phase.warmup => 'warm up, then tap BEGIN REPS',
    Phase.work when s.distanceStep => 'to go',
    Phase.work => 'left in rep',
    Phase.recovery => 'to rep ${s.repIndex + 1}',
    Phase.cooldown => 'tap Stop when done',
    Phase.none => '',
  };
}

class _Header extends StatelessWidget {
  const _Header({
    required this.s,
    required this.maxHr,
    this.compact = false,
    this.trailing,
  });
  final RecordingSnapshot s;
  final int maxHr;
  final bool compact;

  /// The NUMBERS / MAP switch, when a map can be shown.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    // A1: labels render in Bone (or Bone 70 %) on a zone background.
    final secondary = t.inkSecondary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Top line: the phase title and the 5-bar zone gauge. The zone label
        // itself lives under the heart-rate number (founder 30-Sep).
        Row(
          children: [
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  phaseTitle(s),
                  softWrap: false,
                  style: RunSoloType.title28.copyWith(
                    color: phaseTitleColor(s, t),
                  ),
                ),
              ),
            ),
            if (s.hrPaired) ...[
              const SizedBox(width: Space.x8),
              ZoneHeader(
                zone: s.zone,
                paired: s.hrPaired,
                // A1: the gauge keeps the last zone until the tracker's 5 s
                // loss rule; the dropped state reads under the bpm.
                dropped: s.hr == null,
                onZoneBackground: true,
                showLabel: false,
              ),
            ],
            if (trailing != null) ...[
              const SizedBox(width: Space.x4),
              trailing!,
            ],
          ],
        ),
        const SizedBox(height: Space.x8),
        // Founder (tester 0.2): heart rate and total time readable at arm's
        // length, not top-bar text. Free run's big timer already is the
        // total, so it shows heart rate only.
        _Vitals(
          s: s,
          maxHr: maxHr,
          showTotal: s.mode != RecordMode.free && s.mode != RecordMode.trail,
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
    this.valueKey,
    this.distance = false,
  });
  final String label;
  final String value;
  final Color labelColor;
  final Color valueColor;
  final Key? valueKey;

  /// [value] is a distance ("0.40 km"): it rolls as an odometer when
  /// [kOdometerDistance] is on.
  final bool distance;

  static final TextStyle style = RunSoloType.display44.copyWith(
    fontSize: RunSoloType.runSize(36),
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: RunLabelScope.style(context, labelColor)),
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: distance && kOdometerDistance
            ? OdometerDistance(
                key: valueKey,
                value: value,
                style: style.copyWith(color: valueColor),
              )
            : Text(
                value,
                key: valueKey,
                softWrap: false,
                style: style.copyWith(color: valueColor),
              ),
      ),
    ],
  );
}

/// The CLIMB cluster: climb so far and the current grade side by side,
/// aligned (founder 2-Oct, clustered 3-Oct). Same 36 sp floor as every other
/// number on the screen (A8). [showGrade] false (a short phone following a
/// route) leaves the climb alone. The phone's barometer and GPS are fused on
/// the device; nothing here leaves it.
class ElevationRow extends StatelessWidget {
  const ElevationRow({
    super.key,
    required this.s,
    required this.units,
    required this.labelColor,
    required this.valueColor,
    this.showGrade = true,
  });
  final RecordingSnapshot s;
  final Units units;
  final Color labelColor;
  final Color valueColor;
  final bool showGrade;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: const ValueKey('elevation-row'),
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          flex: showGrade ? 2 : 1,
          child: AuxFigure(
            label: 'CLIMB',
            value: Fmt.elevation(s.elevGainM, units),
            labelColor: labelColor,
            valueColor: valueColor,
            valueKey: const ValueKey('live-climb'),
          ),
        ),
        const SizedBox(width: Space.x16),
        Expanded(
          flex: showGrade ? 3 : 1,
          child: showGrade
              ? GradeFigure(
                  pct: s.gradePct,
                  labelColor: labelColor,
                  valueColor: valueColor,
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// The grade as a word on a colour chip (Flat, Gentle, Climb, Steep, Very
/// steep, Down, Steep down), the word at the same size as every other
/// in-run number. The percentage stays, small, beside the label.
class GradeFigure extends StatelessWidget {
  const GradeFigure({
    super.key,
    required this.pct,
    required this.labelColor,
    required this.valueColor,
  });
  final double? pct;
  final Color labelColor;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    final band = GradeBand.of(pct);
    final label = RunLabelScope.style(context, labelColor);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('GRADE', style: label),
            if (band != null) ...[
              const SizedBox(width: Space.x8),
              Text(
                Fmt.grade(pct),
                key: const ValueKey('live-grade-pct'),
                style: label,
              ),
            ],
          ],
        ),
        if (band == null)
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              '--',
              key: const ValueKey('live-grade'),
              softWrap: false,
              style: AuxFigure.style.copyWith(color: valueColor),
            ),
          )
        else
          DecoratedBox(
            key: ValueKey('live-grade-chip-${band.name}'),
            decoration: BoxDecoration(
              color: band.fill,
              borderRadius: BorderRadius.circular(Radii.chip),
              border: Border.all(color: valueColor, width: 2),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.x8,
                vertical: Space.x4,
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  band.word,
                  key: const ValueKey('live-grade'),
                  softWrap: false,
                  style: AuxFigure.style.copyWith(color: band.ink),
                ),
              ),
            ),
          ),
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
      fontSize: RunSoloType.runSize(compact ? 40 : 52),
    );
    final label = RunLabelScope.style(context, secondary);
    // Short reps (plan §3.7, A8): HR lags a 30 s effort, so in a rep the
    // cell shows the rep's max instead of the live reading.
    final repMax =
        s.shortReps &&
        s.phase == Phase.work &&
        s.stepMaxHr != null &&
        s.hr != null;
    final hr = repMax ? s.stepMaxHr : s.hr;
    final pct = hr == null || maxHr <= 0 ? null : (hr * 100 / maxHr).round();
    Widget cell(
      String title,
      Widget value, {
      IconData? icon,
      bool end = false,
    }) => Column(
      crossAxisAlignment: end
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 12, color: t.hrZone),
              const SizedBox(width: Space.x4),
            ],
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(title, softWrap: false, style: label),
              ),
            ),
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
              // Founder 30-Sep: the only zone label on the screen, under the
              // bpm; the header keeps just the gauge.
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
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
                              ? RunSoloType.runNote.copyWith(color: t.semWarn)
                              : AuxFigure.style.copyWith(color: secondary),
                        ),
                      ),
                    ],
                  ),
                  // One line, scaled down rather than run into TOTAL
                  // (24-Oct review #10, font scale 1.3).
                  // Event and goal runs keep the line (blank) until the first
                  // HR and while the strap reconnects: their figures are
                  // centred under this row, so they would shift when HR
                  // arrives or drops (26-Oct).
                  if ((s.zone > 0 && s.hr != null) || isEventRun(s) || s.isGoal)
                    ExcludeSemantics(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          s.zone > 0 && s.hr != null
                              ? HrZones.label(s.zone, paired: true)
                              : ' ',
                          key: s.zone > 0 && s.hr != null
                              ? const ValueKey('vitals-zone')
                              : null,
                          softWrap: false,
                          style: label.copyWith(
                            color: HrZones.labelOn(s.zone, secondary),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              icon: Icons.favorite,
            ),
          ),
        ),
      // TOTAL sits flush right beside a heart rate, so the zone label under
      // the bpm has the gap between them (24-Oct review #10).
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
            end: s.hrPaired,
          ),
        ),
    ];
    if (cells.isEmpty) return const SizedBox.shrink();
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: cells);
  }
}

/// Free run (A2): exactly four numbers, no lap counter, no ghost line.
/// The 12-minute test (C1, A5): in the warm-up a count-up and the run's
/// distance; in the test the count-down from 12:00 and the test's own
/// distance; after 0:00 a cool-down count-up with "Cool down, then stop".
class _CooperBlock extends StatelessWidget {
  const _CooperBlock({
    required this.s,
    required this.ctl,
    required this.units,
    this.compact = false,
    this.card,
  });

  final RecordingSnapshot s;
  final RecordingController ctl;
  final Units units;
  final bool compact;

  /// LV2 (A10.1): during the test the card covers the metres (the countdown
  /// is primary).
  final LayerLink? card;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final secondary = t.inkSecondary;
    final testing = s.phase == Phase.work;
    final (clockMs, caption) = cooperClock(s, ctl);
    final metres = testing || s.phase == Phase.cooldown
        ? s.lapDistanceM
        : s.totalDistanceM;
    return Column(
      key: const ValueKey('cooper-block'),
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            Fmt.clock(clockMs),
            key: const ValueKey('timer'),
            softWrap: false,
            style: (compact ? RunSoloType.display96 : RunSoloType.timer120)
                .copyWith(color: t.inkPrimary),
          ),
        ),
        Text(
          caption,
          key: const ValueKey('cooper-caption'),
          style: RunSoloType.runNote.copyWith(color: secondary),
        ),
        SizedBox(height: compact ? Space.x8 : Space.x16),
        CompareSlot(
          link: testing ? card : null,
          // In the test the slot is at least the card's height, so the card
          // ends above the pace line and never half covers it (#77 P3).
          // Always this tall in the test: nothing jumps when a card shows.
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: testing ? CompareCard.heightFor(compact: compact) : 0,
            ),
            child: Align(
              alignment: Alignment.topCenter,
              heightFactor: 1,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  testing ? '${metres.round()} m' : Fmt.distance(metres, units),
                  key: const ValueKey('cooper-distance-live'),
                  softWrap: false,
                  // The test's metres are the figure that matters; around it the
                  // distance steps down a size.
                  style: switch ((testing, compact)) {
                    (true, false) => RunSoloType.display96,
                    (true, true) || (false, false) => RunSoloType.display64,
                    (false, true) => RunSoloType.display44,
                  }.copyWith(color: testing ? t.inkPrimary : secondary),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: Space.x8),
        AuxFigure(
          label: 'PACE',
          value: Fmt.pace(s.livePaceSecPerKm, units),
          labelColor: secondary,
          valueColor: t.inkPrimary,
        ),
      ],
    );
  }
}

class _FreeRunBlock extends StatelessWidget {
  const _FreeRunBlock({
    required this.s,
    required this.ctl,
    required this.units,
    required this.maxHr,
    this.compact = false,
    this.card,
    this.reserveCard = false,
    this.cardShowing = false,
    this.trail,
  });

  /// The matched known trail, if any. Its gap sits above the trio at the
  /// trio's own size (TIME's), and the plan fitting counts its height.
  final TrailProgress? trail;

  /// The compare card may show: it gets a slot of its own below the
  /// clusters, so it covers no live number. Where the phone is too short for
  /// that, it covers the pace cluster and that hides while it shows (A10.1:
  /// covered = hidden).
  final bool reserveCard;
  final bool cardShowing;
  final RecordingSnapshot s;
  final RecordingController ctl;
  final Units units;
  final int maxHr;

  /// The live compare card's slot link, over the time / distance row.
  final LayerLink? card;

  /// Short screen (< 720 dp): each number one step down.
  final bool compact;

  /// The dial's current pace at the trio's size (24-Oct review #1): the
  /// dial, not a size step, is what sets it apart.
  static double _dialPaceSize(double size) => size;

  static double _textH(TextStyle style) {
    final p = TextPainter(
      text: TextSpan(text: '0', style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    return p.height;
  }

  /// The RUN trio's height at [size]: distance, then time and average pace
  /// side by side, all at [size].
  static double _trioH(double size) {
    final row =
        _textH(RunSoloType.runLabel) +
        _textH(RunSoloType.display44.copyWith(fontSize: size));
    return 2 * row + Space.x4;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final secondary = t.inkSecondary;
    final runAverage = runAverageSecPerKm(s, ctl);
    // Page 1 is the run numbers only (Ricki 11-Oct): distance, time and
    // average pace big, then the current-pace dial. Climb, route and
    // retrace readouts live on the map page; TRUE PACE is post-run only.
    final cardH = CompareCard.heightFor(compact: compact);
    // The card's slot is zero tall until a card shows, then opens (and
    // closes) over ~250 ms, pushing the pace cluster down instead of
    // covering it. Reduced motion: instant.
    final slotOpen = reserveCard && cardShowing;
    return Expanded(
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: slotOpen ? 1.0 : 0.0),
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        builder: (context, open, _) => LayoutBuilder(
          builder: (context, c) {
            const divider = 1.0;
            const minGap = Space.x8 + divider;
            final width = c.maxWidth;
            final half = (width - Space.x16) / 2;
            // Plans from the roomiest to the leanest. The numbers are
            // bigger than before the route readouts moved off this page.
            final plans = <_FreePlan>[
              _FreePlan(
                RunSoloType.runSize(compact ? 76 : 96),
                half,
                big: true,
              ),
              _FreePlan(
                RunSoloType.runSize(compact ? 60 : 72),
                half,
                big: true,
              ),
              _FreePlan(RunSoloType.runSize(compact ? 60 : 72), half),
              _FreePlan(RunSoloType.runSize(compact ? 56 : 64), half),
              _FreePlan(RunSoloType.runSize(compact ? 52 : 56), 112),
              _FreePlan(RunSoloType.runSize(44), 112),
              _FreePlan(RunSoloType.runSize(40), 96),
            ];
            double heightOf(_FreePlan p, {required double slot}) =>
                _planH(p, width, minGap) + slot;
            final full = minGap + cardH;
            final reserve =
                reserveCard &&
                plans.any((p) => heightOf(p, slot: full) <= c.maxHeight);
            final slot = reserve ? open * full : 0.0;
            _FreePlan? fit;
            for (final p in plans) {
              if (heightOf(p, slot: slot) <= c.maxHeight) {
                fit = p;
                break;
              }
            }
            final plan = fit ?? plans.last;
            final size = EqualFigures.sizeFor(width, plan.trioCap);
            final dial = plan.big
                ? Center(
                    child: SizedBox(
                      width: width * 0.6,
                      child: PaceDial(
                        currentSecPerKm: s.livePaceSecPerKm,
                        referenceSecPerKm: runAverage,
                        units: units,
                        onZone: true,
                        paceStyle: AuxFigure.style.copyWith(
                          fontSize: _dialPaceSize(size),
                        ),
                      ),
                    ),
                  )
                : PaceDial(
                    currentSecPerKm: s.livePaceSecPerKm,
                    referenceSecPerKm: runAverage,
                    units: units,
                    onZone: true,
                    beside: true,
                    dialWidth: plan.dialWidth == half ? null : plan.dialWidth,
                    paceStyle: AuxFigure.style.copyWith(
                      fontSize: _dialPaceSize(size),
                    ),
                  );
            final clusters = <Widget>[
              _FreeFigures(
                figures: liveHero(s, ctl, units).figures,
                valueKeys: const [
                  ValueKey('free-distance'),
                  ValueKey('timer'),
                  ValueKey('run-average'),
                ],
                size: size,
                labelColor: secondary,
                valueColor: t.inkPrimary,
                odometer: kOdometerDistance
                    ? (style) => FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: OdometerDistance(
                          value: liveHero(s, ctl, units).figures.first.value,
                          style: style,
                        ),
                      )
                    : null,
              ),
              dial,
            ];
            final contentH = heightOf(plan, slot: slot);
            final gaps = clusters.length - 1 + (reserve ? open : 0);
            final share = (c.maxHeight - contentH) / (gaps + 2);
            final top = share.clamp(0.0, Space.x32);
            final between = (minGap + share).clamp(minGap, 96.0);
            Widget sep() => SizedBox(
              height: between,
              child: Center(
                child: Container(height: divider, color: t.lineHair),
              ),
            );
            final children = <Widget>[
              SizedBox(height: top),
              // The gap to the run being raced, at TIME's size.
              if (trail case final tr?)
                TrailGhostReadout(trail: tr, valueSize: size),
            ];
            // Without a slot of its own the card covers the pace cluster
            // while it shows; it hides then.
            final cover = !reserve && reserveCard;
            for (var i = 0; i < clusters.length; i++) {
              if (i == 1) children.add(sep());
              if (i == 1 && cover) {
                children.add(
                  CompareSlot(
                    link: card,
                    child: Visibility(
                      visible: !cardShowing,
                      maintainSize: true,
                      maintainAnimation: true,
                      maintainState: true,
                      child: clusters[i],
                    ),
                  ),
                );
              } else {
                children.add(clusters[i]);
              }
            }
            if (reserve) {
              children.add(SizedBox(height: open * between));
              children.add(
                CompareSlot(
                  link: card,
                  child: SizedBox(width: double.infinity, height: open * cardH),
                ),
              );
            }
            return Column(
              key: const ValueKey('free-run-block'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            );
          },
        ),
      ),
    );
  }

  double _planH(_FreePlan p, double width, double minGap) {
    final size = EqualFigures.sizeFor(width, p.trioCap);
    final label = _textH(RunSoloType.runLabel);
    final double pace;
    if (p.big) {
      final w = width * 0.6;
      pace =
          w / 2 +
          Space.x4 +
          _textH(AuxFigure.style.copyWith(fontSize: _dialPaceSize(size))) +
          label;
    } else {
      final paceCol =
          label +
          _textH(AuxFigure.style.copyWith(fontSize: _dialPaceSize(size)));
      pace = paceCol > p.dialWidth / 2 ? paceCol : p.dialWidth / 2;
    }
    final ghost = trail == null
        ? 0.0
        : TrailGhostReadout.heightFor(trail!, size);
    return ghost + _trioH(size) + minGap + pace;
  }
}

/// Free / Trail numbers (founder 3-Oct, restored 24-Oct UI review #1):
/// distance, time and average pace at ONE size, distance first on its own
/// row, time and average pace side by side under it. [figures] is distance,
/// time, average pace; [size] the shared size.
class _FreeFigures extends StatelessWidget {
  const _FreeFigures({
    required this.figures,
    required this.valueKeys,
    required this.size,
    required this.labelColor,
    required this.valueColor,
    this.odometer,
  });
  final List<LiveFigure> figures;
  final List<Key> valueKeys;
  final double size;
  final Color labelColor;
  final Color valueColor;
  final Widget Function(TextStyle style)? odometer;

  @override
  Widget build(BuildContext context) {
    final style = RunSoloType.display44.copyWith(
      fontSize: size,
      fontWeight: FontWeight.w700,
      color: valueColor,
    );
    Widget one(int i) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(figures[i].label, style: RunLabelScope.style(context, labelColor)),
        if (i == 0 && odometer != null)
          KeyedSubtree(key: valueKeys[i], child: odometer!(style))
        else
          Text(
            figures[i].value,
            key: valueKeys[i],
            softWrap: false,
            maxLines: 1,
            overflow: TextOverflow.visible,
            style: style,
          ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        one(0),
        const SizedBox(height: Space.x4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: one(1)),
            const SizedBox(width: Space.x16),
            Expanded(child: one(2)),
          ],
        ),
      ],
    );
  }
}

class _FreePlan {
  const _FreePlan(this.trioCap, this.dialWidth, {this.big = false});
  final double trioCap;
  final double dialWidth;

  /// The stacked speedo (arc, then the pace under it) when there is room.
  final bool big;
}

/// The two run pages: 1 the numbers, 2 the map and route readouts.
///
/// Gesture approach: a plain horizontal PageView that always scrolls, in both
/// directions, from anywhere. The live map is display-only (see
/// [LiveMapView]): its platform view used to claim the horizontal drag on
/// pointer down, so on page 2 the pager had to be NeverScrollable and the way
/// back was a left-edge strip and a Listener hack that failed on a device
/// (12, 14 and 17-Oct). With the map ignoring touches there is nothing to
/// fight over, so those are gone. Page dots, the NUMBERS button and system
/// back still go back too. Unproven on hardware: the fake map in tests never
/// claimed the arena, so no widget test could show the original failure.
class _RunPages extends StatelessWidget {
  const _RunPages({
    super.key,
    required this.controller,
    required this.twoPages,
    required this.onPage,
    required this.one,
    required this.two,
  });
  final PageController controller;
  final bool twoPages;
  final ValueChanged<int> onPage;
  final Widget one;
  final Widget two;

  @override
  Widget build(BuildContext context) {
    if (!twoPages) return one;
    return PageView(
      controller: controller,
      onPageChanged: onPage,
      physics: const PageScrollPhysics(),
      children: [one, two],
    );
  }
}

/// The big way between the two run pages: a full-width, 56 dp button, in the
/// same place on both (page 2: NUMBERS with a back arrow, page 1: MAP with a
/// forward one). A second way across beside the swipe and the system back
/// gesture (14-Oct: the swipe alone failed on the phone).
class PageSwitchButton extends StatelessWidget {
  const PageSwitchButton({
    super.key,
    required this.buttonKey,
    required this.label,
    required this.semantics,
    required this.forward,
    required this.onTap,
  });

  /// Page 2's way back to the numbers.
  const PageSwitchButton.numbers({super.key, required this.onTap})
    : buttonKey = const ValueKey('page-numbers-button'),
      label = 'NUMBERS',
      semantics = 'Show numbers',
      forward = false;

  /// Page 1's way on to the map.
  const PageSwitchButton.map({super.key, required this.onTap})
    : buttonKey = const ValueKey('page-map-button'),
      label = 'MAP',
      semantics = 'Show map',
      forward = true;

  final Key buttonKey;
  final String label;
  final String semantics;
  final bool forward;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final arrow = Icon(
      forward ? Icons.arrow_forward_rounded : Icons.arrow_back_rounded,
      size: 28,
      color: t.inkPrimary,
    );
    return Semantics(
      button: true,
      label: semantics,
      excludeSemantics: true,
      child: Material(
        color: t.bgRaised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.button),
          side: BorderSide(color: t.inkPrimary, width: 2),
        ),
        child: InkWell(
          key: buttonKey,
          customBorder: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.button),
          ),
          onTap: onTap,
          child: SizedBox(
            height: 56,
            width: double.infinity,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (!forward) ...[arrow, const SizedBox(width: Space.x8)],
                CapsText(
                  label,
                  style: RunSoloType.display44.copyWith(
                    fontSize: RunSoloType.runSize(28),
                    color: t.inkPrimary,
                  ),
                ),
                if (forward) ...[const SizedBox(width: Space.x8), arrow],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Two dots in the header: which page is showing, and a 48 dp tap to switch.
class PageDots extends StatelessWidget {
  const PageDots({super.key, required this.page, required this.onTap});
  final int page;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Semantics(
      button: true,
      label: page == 0 ? 'Show map' : 'Show numbers',
      excludeSemantics: true,
      child: InkResponse(
        key: const ValueKey('page-dots'),
        onTap: () => onTap(page == 0 ? 1 : 0),
        radius: 24,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < 2; i++)
                Container(
                  width: i == page ? 14 : 10,
                  height: i == page ? 14 : 10,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: t.inkPrimary.withValues(alpha: i == page ? 1 : 0.4),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TimerBlock extends StatelessWidget {
  const _TimerBlock({
    required this.s,
    required this.ctl,
    this.style,
    this.hideCaption = false,
  });
  final RecordingSnapshot s;
  final RecordingController ctl;

  /// Digits style; timer120 unless a bigger primary number shares the screen.
  final TextStyle? style;

  /// The next-step line already says "... left" (short phones): the caption
  /// under the countdown gives its room to the coach layer.
  final bool hideCaption;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final secondary = t.inkSecondary;
    final recovery = s.phase == Phase.recovery;
    final ms = timerFigureMs(s, ctl);
    final toGo = s.metresToGo;
    final target = s.currentStep?.value ?? 0;
    final total = !recovery && s.phase != Phase.work
        ? 0
        : s.phaseDurationMs > 0
        ? s.phaseDurationMs
        : recovery
        ? s.recoveryMs
        : 0;
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
        timerFigureText(s, ctl),
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
        // Founder 30-Sep: rep and recovery share one outlined countdown.
        if (recovery || s.phase == Phase.work)
          CustomPaint(
            painter: _RecoveryRingPainter(
              progress: progress,
              color: secondary,
              track: t.lineHair,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                vertical: 0,
                horizontal: Space.x24,
              ),
              child: digits,
            ),
          )
        else
          digits,
        if (!hideCaption) ...[
          const SizedBox(height: Space.x4),
          Text(
            s.paused ? '' : timerCaption(s),
            style: RunSoloType.runCaption.copyWith(color: secondary),
          ),
        ],
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
    this.hideAverage = false,
  });
  final RecordingSnapshot s;
  final RecordingController ctl;
  final Units units;

  /// Short screen (< 720 dp): every number one step down, same order.
  final bool compact;

  /// The live compare card is over the average (LV2): hide it and its
  /// label, keeping their space.
  final bool hideAverage;

  static double _lineHeight(BuildContext context, TextStyle style) =>
      (TextPainter(
        text: TextSpan(text: '0', style: style),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
      )..layout()).height;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final secondary = t.inkSecondary;
    final segmentAvg = segmentAverage(s, ctl);
    final reference = s.phase == Phase.work
        ? (s.lastRepPaceSecPerKm ?? segmentAvg)
        : segmentAvg;
    final title = switch (s.phase) {
      Phase.work => 'REP AVERAGE',
      Phase.recovery => 'RECOVERY AVERAGE',
      _ => 'SEGMENT AVERAGE',
    };
    // No average yet (the first seconds of a rep, or no fix): never a bare
    // "--", which at this size reads as two broken bars (24-Oct review #11).
    // A muted word says why; the dial already has the current pace.
    final settling = segmentAvg == null;
    final avgText = !settling
        ? Fmt.pace(segmentAvg, units)
        : (s.gpsLost || s.showEndRep ? 'NO GPS' : 'SETTLING');
    final unit = units == Units.mi ? 'mi' : 'km';
    final caption = settling ? title : '$title /$unit';
    final paceStyle =
        primaryStyle(compact, secondary: s.phase == Phase.recovery).copyWith(
          color: s.phase == Phase.recovery || settling
              ? secondary
              : t.inkPrimary,
          fontWeight: FontWeight.w700,
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Visibility(
          visible: !hideAverage,
          maintainSize: true,
          maintainAnimation: true,
          maintainState: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (settling)
                // The word is a status, not a number: 56 sp, in the pace's
                // own height so nothing moves when the average arrives.
                SizedBox(
                  height: _lineHeight(context, paceStyle),
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.bottomLeft,
                      child: Text(
                        avgText,
                        key: const ValueKey('segment-avg'),
                        softWrap: false,
                        style: paceStyle.copyWith(
                          fontSize: RunSoloType.runSize(56),
                        ),
                      ),
                    ),
                  ),
                )
              else
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    avgText,
                    key: const ValueKey('segment-avg'),
                    softWrap: false,
                    // The biggest number in a rep; second to the countdown in
                    // a recovery. The FittedBox only shrinks it for a wide
                    // value.
                    style: paceStyle,
                  ),
                ),
              Text(
                caption,
                key: const ValueKey('segment-avg-caption'),
                style: RunSoloType.runCaption.copyWith(color: secondary),
              ),
            ],
          ),
        ),
        // With no fix there is no live pace or distance to show here, and
        // the GPS banner (and END REP) need the room on a short phone.
        if (!s.showEndRep && !s.gpsLost) ...[
          SizedBox(height: compact ? Space.x4 : Space.x8),
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
                  onZone: true,
                  // 16 sp "CURRENT PACE" wraps in the 112 dp dial column.
                  label: compact ? 'PACE' : 'CURRENT PACE',
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
    Color deltaColor = t.inkSecondary;
    String? delta;
    DeltaDirection? direction;
    if (showGhost && live != null) {
      final g = ghostDelta(live, last, units);
      delta = g.text;
      direction = g.direction;
      // A1: Vermillion and Arc deltas are the flood's foreground (Bone, or
      // ink on the bright floods) with the arrow, on every flood.
      deltaColor = t.inkPrimary;
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
                // m:ss/km with no space: one run of text, the unit a small
                // caption on the same baseline.
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: Fmt.pace(live, units)),
                      if (live != null)
                        TextSpan(
                          text: '/${units == Units.mi ? 'mi' : 'km'}',
                          style: RunSoloType.runCaption.copyWith(
                            color: t.inkSecondary,
                          ),
                        ),
                    ],
                  ),
                  softWrap: false,
                  style: RunSoloType.display44.copyWith(color: t.inkPrimary),
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
            style: RunSoloType.runNote.copyWith(color: deltaColor),
          )
        else
          // A8: no number on the record screen under 36 sp.
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                s.isPreset ? 'last rep ' : 'last lap ',
                style: RunSoloType.runNote.copyWith(color: deltaColor),
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
        style: RunSoloType.runCaption.copyWith(color: t.inkPrimary),
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
                    style: RunSoloType.runCaption.copyWith(color: t.inkPrimary),
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

/// STOP (Ricki 26-Sep): a single tap; the finish screen after it catches a
/// pocket or accidental tap (RESUME).
class _StopButton extends StatelessWidget {
  const _StopButton({required this.onTap});
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Semantics(
      button: true,
      label: 'Stop',
      excludeSemantics: true,
      child: InkWell(
        key: const ValueKey('stop'),
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
              Icon(Icons.stop, size: 20, color: t.inkPrimary),
              const SizedBox(width: Space.x8),
              Text(
                'STOP',
                style: RunSoloType.runCaption.copyWith(color: t.inkPrimary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// After STOP (Ricki 26-Sep): the clock stopped at the tap. SAVE is the
/// primary and biggest; RESUME carries on (the gap is a pause, excluded);
/// DISCARD asks again. The time is A8-size (≥ 36 sp).
class _FinishScreen extends StatelessWidget {
  const _FinishScreen({
    required this.ctl,
    required this.elapsedMs,
    required this.units,
    required this.error,
    required this.onSave,
    required this.onResume,
    required this.onDiscard,
  });
  final RecordingController ctl;

  /// null: the recorder is still running (pause failed), show the live
  /// clock.
  final int? elapsedMs;
  final Units units;
  final String? error;
  final Future<void> Function() onSave;
  final Future<void> Function() onResume;
  final Future<void> Function() onDiscard;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final s = ctl.snapshot;
    return ColoredBox(
      key: const ValueKey('finish-screen'),
      color: t.bgBase,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Space.screenGutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Text(
                'FINISHED?',
                textAlign: TextAlign.center,
                style: RunSoloType.title28.copyWith(color: t.inkSecondary),
              ),
              const SizedBox(height: Space.x16),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  Fmt.clock(elapsedMs ?? ctl.displayElapsedMs),
                  key: const ValueKey('finish-time'),
                  style: RunSoloType.display96.copyWith(color: t.inkPrimary),
                ),
              ),
              Text(
                goalDistanceText(s.totalDistanceM, units),
                key: const ValueKey('finish-distance'),
                textAlign: TextAlign.center,
                style: RunSoloType.display44.copyWith(color: t.inkSecondary),
              ),
              const Spacer(),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.x12),
                  child: Text(
                    error!,
                    style: RunSoloType.runNote.copyWith(color: t.semDanger),
                  ),
                ),
              FilledButton(
                key: const ValueKey('finish-save'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(96),
                  textStyle: RunSoloType.display44,
                ),
                onPressed: onSave,
                child: const Text('SAVE'),
              ),
              const SizedBox(height: Space.x12),
              OutlinedButton(
                key: const ValueKey('finish-resume'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(64),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(Radii.button),
                  ),
                  textStyle: RunSoloType.title28,
                ),
                onPressed: onResume,
                child: const Text('RESUME'),
              ),
              const SizedBox(height: Space.x8),
              TextButton(
                key: const ValueKey('finish-discard'),
                style: TextButton.styleFrom(
                  minimumSize: const Size.fromHeight(56),
                ),
                onPressed: onDiscard,
                child: Text(
                  'Discard run',
                  style: RunSoloType.runNote.copyWith(color: t.semDanger),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The spare room under a hero block: the coach layer sits at its bottom when
/// it fits, and the room stays empty when it does not (short phones), so it
/// never pushes the numbers or the controls.
class _CoachSlot extends StatelessWidget {
  const _CoachSlot(this.coach);
  final _CoachLayer? coach;

  @override
  // Flex 3 against the lone Spacer above the numbers: the coach layer gets
  // the room first, so the 16 sp label floor never costs the next-step line.
  Widget build(BuildContext context) => Expanded(
    flex: 3,
    child: LayoutBuilder(
      builder: (context, box) {
        final c = coach;
        // Short phones scale it down a little rather than lose it.
        if (c == null || box.maxHeight < c.height * 0.75) {
          return const SizedBox.shrink();
        }
        return Align(
          alignment: Alignment.bottomCenter,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: SizedBox(width: box.maxWidth, child: c),
          ),
        );
      },
    ),
  );
}

/// The coach layer under the numbers (Full Instrument): the target band bar
/// and the next-step line. Built only for a session with something to say;
/// Free runs without a target get neither.
class _CoachLayer extends StatelessWidget {
  const _CoachLayer({
    required this.target,
    required this.smoothed,
    required this.units,
    required this.labelColor,
    required this.textColor,
    required this.nextLine,
    required this.labelSize,
  });
  final CoachTarget? target;
  final double labelSize;
  final double? smoothed;
  final Units units;
  final Color labelColor;
  final Color textColor;
  final String? nextLine;

  /// Room the layer needs, for [_CoachSlot] to decide whether it fits.
  double get height =>
      (target != null ? TargetBand.heightFor(labelSize) : 0) +
      (target != null && nextLine != null ? 2.0 : 0) +
      (nextLine != null ? 20.0 : 0);

  static _CoachLayer? of({
    required RecordingSnapshot s,
    required RecordingController ctl,
    required double? smoothed,
    required Units units,
    required Color labelColor,
    required Color textColor,
    required double labelSize,
  }) {
    // The band is for the pace-targeted part: a rep or goal's work, or a
    // plan session run as a Free run. Not warm-up, recovery or cool-down.
    final target = ctl.coachTarget;
    final band = target != null && (!s.isPreset || s.phase == Phase.work)
        ? target
        : null;
    final next = s.isPreset ? nextStepText(s.spec, s.phase, s.stepIndex) : null;
    String? line;
    if (next != null) {
      final String? left;
      if (s.phase != Phase.work && s.phase != Phase.recovery) {
        left = null;
      } else if (s.distanceStep) {
        final m = s.metresToGo;
        // The same rounding as the countdown pill (metresText), and "--"
        // while GPS is lost, so the two never disagree (S7).
        left = m == null
            ? null
            : '${s.gpsLost || s.showEndRep ? '--' : metresText(m)} left';
      } else {
        left = '${Fmt.clock(ctl.displayRemainingMs)} left';
      }
      line = left == null ? 'then $next' : '$left · then $next';
    }
    if (band == null && line == null) return null;
    return _CoachLayer(
      target: band,
      smoothed: smoothed,
      units: units,
      labelColor: labelColor,
      textColor: textColor,
      nextLine: line,
      labelSize: labelSize,
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    key: const ValueKey('coach-layer'),
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (target != null)
        TargetBand(
          target: target!,
          paceSecPerKm: smoothed,
          units: units,
          labelColor: labelColor,
        ),
      if (target != null && nextLine != null) const SizedBox(height: 2),
      if (nextLine != null)
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            nextLine!,
            key: const ValueKey('next-step'),
            softWrap: false,
            style: RunSoloType.title28.copyWith(
              color: textColor,
              fontSize: 20,
              height: 1.0,
            ),
          ),
        ),
    ],
  );
}

/// The run so far for the paused screen: distance, time, average pace,
/// whatever the run type (the hero of a structured run is a phase figure that
/// means little while stopped).
List<LiveFigure> runSoFarFigures(
  RecordingSnapshot s,
  RecordingController ctl,
  Units units,
) {
  final unit = units == Units.mi ? 'mi' : 'km';
  return [
    LiveFigure(label: 'DISTANCE', value: Fmt.distance(s.totalDistanceM, units)),
    LiveFigure(label: 'TIME', value: Fmt.clock(ctl.displayElapsedMs)),
    LiveFigure(
      label: 'AVG PACE /$unit',
      value: Fmt.pace(runAverageSecPerKm(s, ctl), units),
    ),
  ];
}

/// O7: while paused the LAP button and the live numbers give way to the run
/// so far (distance, time, average pace) at the free-run size, and one big
/// RESUME. STOP stays in the control row below.
class _PausedPanel extends StatelessWidget {
  const _PausedPanel({
    required this.figures,
    required this.onResume,
    required this.secondary,
    required this.compact,
    this.note,
    this.auto = false,
  });
  final List<LiveFigure> figures;
  final Future<void> Function() onResume;
  final Color secondary;
  final bool compact;

  /// The recorder paused itself (Settings → Auto-pause): AUTO-PAUSED.
  final bool auto;

  /// One line under PAUSED (a paused 12-minute test gives no estimate).
  final String? note;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return LayoutBuilder(
      builder: (context, c) => Center(
        // Scales down rather than overflow on a short phone with a note.
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: c.maxWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  auto ? 'AUTO-PAUSED' : 'PAUSED',
                  key: const ValueKey('paused-title'),
                  style: RunSoloType.title28.copyWith(color: secondary),
                ),
                if (note != null) ...[
                  const SizedBox(height: Space.x8),
                  Text(
                    note!,
                    key: const ValueKey('paused-note'),
                    style: RunSoloType.runNote.copyWith(color: t.inkPrimary),
                  ),
                ],
                const SizedBox(height: Space.x16),
                EqualFigures(
                  figures: figures,
                  valueKeys: const [
                    ValueKey('paused-distance'),
                    ValueKey('paused-time'),
                    ValueKey('paused-pace'),
                  ],
                  cap: compact ? 52 : 64,
                  labelColor: secondary,
                  valueColor: t.inkPrimary,
                ),
                const SizedBox(height: Space.x24),
                FilledButton(
                  key: const ValueKey('resume'),
                  style: FilledButton.styleFrom(
                    minimumSize: Size.fromHeight(compact ? 80 : 96),
                    textStyle: RunSoloType.display44,
                  ),
                  onPressed: onResume,
                  child: const Text('RESUME'),
                ),
              ],
            ),
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

/// Warm-up of a distance session without a fix (W3): BEGIN REPS stays off
/// until GPS is back, and says why.
class _WaitingForGps extends StatelessWidget {
  const _WaitingForGps({required this.height, required this.label});
  final double height;

  /// The session's own start label: BEGIN REPS for a preset, BEGIN TEST
  /// for the 12-minute test (field test 27-Sep).
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Semantics(
      button: true,
      enabled: false,
      label: '${label[0]}${label.substring(1).toLowerCase()}. Waiting for GPS',
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
              label,
              style: RunSoloType.display44.copyWith(color: t.inkSecondary),
            ),
            Text(
              'waiting for GPS',
              style: RunSoloType.runNote.copyWith(color: t.semWarn),
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

/// The last 400 m (A10.10), or a time goal's last minute (G3): projected
/// finish becomes the primary number.
bool eventLastStretch(RecordingSnapshot s) => inLastStretch(s);

/// "6.21 km" / "3.86 mi": a time goal's distance, two decimals.
String goalDistanceText(double metres, Units units) => units == Units.mi
    ? '${(metres / 1609.344).toStringAsFixed(2)} mi'
    : '${(metres / 1000).toStringAsFixed(2)} km';

/// A time goal's projected distance at the goal time: step distance ÷ step
/// time × goal time; null for the first 200 m and without a good fix
/// (never extrapolated, as the event).
double? goalProjectedMetres(RecordingSnapshot s, int stepActiveMs) {
  final st = s.currentStep;
  if (st == null || st.target != TargetKind.time) return null;
  if (s.gpsLost || s.gpsWeak) return null;
  final run = s.lapDistanceM;
  if (run < 200 || stepActiveMs <= 0) return null;
  return run / stepActiveMs * st.value * 1000;
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

/// The goal / event screen's supporting figures (founder 8K field test
/// 29-Sep): distance covered, live pace and the run average - the Free run
/// screen's set - under the countdown and its projection. AuxFigure size
/// keeps the A8 floor ("no number smaller than 36 sp").
class _EventStats extends StatelessWidget {
  const _EventStats({required this.s, required this.ctl, required this.units});
  final RecordingSnapshot s;
  final RecordingController ctl;
  final Units units;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final secondary = t.inkSecondary;
    final activeMs = ctl.displayElapsedMs;
    final avg = s.totalDistanceM > 20 && activeMs > 0
        ? activeMs / 1000 / (s.totalDistanceM / 1000)
        : null;
    // The intervals-block pattern (founder 20-Oct, Goal run: "speedo for
    // current pace, odo for current distance"): COVERED and AVG on the left,
    // the speedo on the right. The snapshot carries no goal target pace, so
    // the dial's reference is the run average.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              AuxFigure(
                label: 'COVERED',
                value: Fmt.distance(s.totalDistanceM, units),
                distance: true,
                labelColor: secondary,
                valueColor: t.inkPrimary,
              ),
              const SizedBox(height: Space.x4),
              AuxFigure(
                label: 'AVG',
                value: avg == null ? '--' : Fmt.pace(avg, units),
                labelColor: secondary,
                valueColor: t.inkPrimary,
              ),
            ],
          ),
        ),
        const SizedBox(width: Space.x16),
        SizedBox(
          width: 152,
          child: PaceDial(
            currentSecPerKm: s.livePaceSecPerKm,
            referenceSecPerKm: avg,
            units: units,
            onZone: true,
            label: 'CURRENT PACE',
            // Second-largest number on the goal / event screen (21-Oct).
            paceStyle: RunSoloType.display64,
          ),
        ),
      ],
    );
  }
}

class EventBlock extends StatelessWidget {
  const EventBlock({
    super.key,
    required this.s,
    required this.ctl,
    required this.units,
    this.compact = false,
    this.reduced = false,
    this.card,
    this.targetMs,
  });
  final RecordingSnapshot s;
  final RecordingController ctl;
  final Units units;
  final bool compact;
  final bool reduced;

  /// A distance goal's target time (ms): the finish line then reads
  /// "TARGET 40:03 · ON PACE FOR 49:50" in one fixed row. Null for events,
  /// time goals and goals with no history to predict from.
  final int? targetMs;

  /// The live compare card, over the projected finish (secondary) before
  /// the last 400 m; none in it (A10.1). The slot's link.
  final LayerLink? card;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final muted = t.inkSecondary;
    final last = eventLastStretch(s);
    final toGoText = eventToGoText(s, ctl, units);
    final finishText = eventFinishText(s, ctl, units);
    Widget number(
      String key,
      String text,
      String label, {
      required bool big,
      bool odo = false,
      bool accent = false,
      String? reference,
      TextStyle? base,
    }) {
      final dashed = text == '--';
      // The last stretch changes emphasis only (accent colour); the size and
      // the digit block's width never move.
      final style = (base ?? primaryStyle(compact, secondary: !big)).copyWith(
        color: accent && !dashed
            ? lastStretchAccent(t, s.zone)
            : big && !dashed
            ? t.inkPrimary
            : muted,
      );
      return Column(
        key: ValueKey(key),
        mainAxisSize: MainAxisSize.min,
        children: [
          // 8 dp of clear air before the zone ladder: the headline scales to
          // fit inside it (21-Oct review).
          Padding(
            padding: const EdgeInsets.only(right: Space.x8),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              // The figure never scales up as it shortens (1.00 km to 990 m,
              // 10.00 km to 9.99 km, 10:00 to 9:59): the block keeps the
              // width of the widest form this run starts from, so size and
              // place hold for the whole run (26-Oct). Measured at the user's
              // text scale, as the figure itself is drawn.
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: _widestBlock(context, style, [
                    if (odo) units == Units.mi ? '8.88 mi' : '8.88 km',
                    ?reference,
                  ]),
                ),
                child: Center(
                  child: odo && kOdometerDistance && !dashed
                      ? OdometerDistance(value: text, style: style)
                      : Text(text, softWrap: false, style: style),
                ),
              ),
            ),
          ),
          Text(label, style: RunSoloType.runCaption.copyWith(color: muted)),
        ],
      );
    }

    // A distance to go rolls like the Free run's odometer; a time goal's
    // clock stays plain text.
    final toGoIsDistance = s.distanceStep || s.metresToGo != null;
    final toGo = number(
      'event-to-go',
      toGoText,
      'to go',
      big: true,
      odo: toGoIsDistance,
      accent: last,
      reference: eventStartText(s, units),
    );
    final target = targetMs;
    final finish = CompareSlot(
      link: last ? null : card,
      child: SizedBox(
        width: double.infinity,
        child: target != null && toGoIsDistance
            // One fixed row from the first metre to the last: TARGET (muted)
            // beside ON PACE FOR (full ink), both well over the 36 sp floor.
            // Nothing in it changes size or place in the last stretch.
            ? Row(
                key: const ValueKey('goal-target-row'),
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: number(
                      'goal-target',
                      _targetClock(target),
                      'TARGET',
                      big: false,
                      reference: eventFinishWidest(s, units),
                      base: RunSoloType.display44,
                    ),
                  ),
                  Expanded(
                    child: number(
                      'event-finish',
                      finishText,
                      'ON PACE FOR',
                      big: true,
                      reference: eventFinishWidest(s, units),
                      base: compact
                          ? RunSoloType.display44
                          : RunSoloType.display64,
                    ),
                  ),
                ],
              )
            : number(
                'event-finish',
                finishText,
                eventFinishLabel(s),
                big: false,
                reference: eventFinishWidest(s, units),
              ),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        toGo,
        SizedBox(height: compact ? Space.x8 : Space.x16),
        finish,
      ],
    );
  }
}

/// G3: after the goal (open cool-down). The cool-down's time is primary; the
/// goal's result is locked in a card ("10K DONE 49:12", "30 MIN DONE
/// 6.21 km"), secondary size.
class GoalDoneBlock extends StatelessWidget {
  const GoalDoneBlock({
    super.key,
    required this.s,
    required this.ctl,
    required this.units,
    this.compact = false,
    this.targetMs,
  });
  final RecordingSnapshot s;
  final RecordingController ctl;
  final Units units;
  final bool compact;

  /// A distance goal's target time (ms), shown with the result locked below
  /// the cool-down: what he aimed for, and how far off the finish landed.
  final int? targetMs;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final muted = t.inkSecondary;
    final byTime = s.spec?.steps.firstOrNull?.target == TargetKind.time;
    final ms = s.goalLapMs;
    final m = s.goalLapM;
    final result = byTime
        ? (m == null ? '--' : goalDistanceText(m, units))
        : (ms == null ? '--' : Fmt.clock(ms));
    return Column(
      key: const ValueKey('goal-done'),
      mainAxisSize: MainAxisSize.min,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            Fmt.clock(ctl.displayLapElapsedMs),
            key: const ValueKey('goal-cooldown'),
            softWrap: false,
            style: primaryStyle(compact).copyWith(color: t.inkPrimary),
          ),
        ),
        Text('cool-down', style: RunSoloType.runCaption.copyWith(color: muted)),
        SizedBox(height: compact ? Space.x8 : Space.x16),
        Container(
          key: const ValueKey('goal-lock'),
          padding: const EdgeInsets.symmetric(
            horizontal: Space.x16,
            vertical: Space.x8,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.card),
            border: Border.all(color: muted),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'GOAL · ${(s.spec?.name ?? '').toUpperCase()}',
                style: RunSoloType.runCaption.copyWith(color: muted),
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  result,
                  key: const ValueKey('goal-result'),
                  softWrap: false,
                  style: primaryStyle(
                    compact,
                    secondary: true,
                  ).copyWith(color: muted),
                ),
              ),
              if (!byTime && targetMs != null && ms != null)
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    targetLine(targetMs!, ms),
                    key: const ValueKey('goal-target-result'),
                    softWrap: false,
                    style: RunSoloType.display44.copyWith(color: muted),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// "TARGET 40:03 · 9:47 OVER": the finish against the target on the
  /// clock, whole seconds each side, so the gap is exactly the difference of
  /// the two clocks printed (never a verdict word).
  @visibleForTesting
  static String targetLine(int targetMs, int finishMs) {
    final targetS = (targetMs / 1000).round();
    final gap = finishMs ~/ 1000 - targetS;
    final tail = gap == 0
        ? 'ON IT'
        : '${Fmt.clock(gap.abs() * 1000)} ${gap > 0 ? 'OVER' : 'UNDER'}';
    return 'TARGET ${Fmt.clock(targetS * 1000)} · $tail';
  }
}

/// In-app "Mute tips" (LV2, lead 26-Sep): Laps and Intervals notifications
/// have no room for the action, so the record screen carries it while this
/// run's tips are on. Coaching off for this run only: no compare speech, no
/// nudges, no card; the Settings toggle is left as it is.
class MuteTipsButton extends StatelessWidget {
  const MuteTipsButton({super.key, required this.onTap});
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Semantics(
      button: true,
      label: 'Mute tips for this run',
      child: InkWell(
        key: const ValueKey('mute-tips'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.button),
        child: ExcludeSemantics(
          // Icon only, 56 dp like Pause and Hold to stop beside it.
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: t.bgRaised,
              borderRadius: BorderRadius.circular(Radii.button),
              border: Border.all(color: t.lineHair),
            ),
            child: Icon(Icons.volume_off, size: 22, color: t.inkPrimary),
          ),
        ),
      ),
    );
  }
}
