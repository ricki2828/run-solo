import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/routes.dart';
import '../app/services.dart';
import '../platform/gateway.dart';
import '../platform/host_caps.dart';
import '../state/settings.dart';
import '../theme/caps_text.dart';
import '../theme/theme.dart';
import '../widgets/coach_choice_row.dart';
import '../widgets/structure_glyph.dart';

/// The Ready screen: the start line. The one place a run says START.
///
/// The Start screen picks the run; this screen is full-bleed in the run
/// type's colour, names the run in display type, says what is planned, shows
/// live checks (GPS, heart-rate strap) and has one huge START. Tapping START
/// runs a full-screen 3-2-1-GO ([AppSettings.countdownSeconds]; 0 = none) with
/// a haptic on each beat, and the recorder starts exactly at GO. Tapping the
/// countdown cancels back here.
///
/// With voice cues on the countdown also says "3, 2, 1, go" through a
/// speech player of its own (no recording session exists yet): it is warmed
/// up when this screen opens, "go" is spoken at the same moment the recorder
/// starts, and cancelling stops it. With voice cues off, or if the speech
/// engine is not ready, it stays haptics and numerals with no error.
///
/// The screen owns no recorder logic: [onGo] is the Start screen's start
/// call (settings pushed to the recorder, live compare, `recording.start`).
class ReadyScreen extends StatefulWidget {
  const ReadyScreen({
    super.key,
    required this.runType,
    required this.ground,
    required this.plan,
    required this.probe,
    required this.onGo,
    this.target,
    this.structure,
    this.structureLine,
    this.lastRun,
    this.requiresGps = false,
    this.asksCoachChoice = false,
    this.onChange,
  });

  /// "INTERVALS", "FREE RUN" ...: the big words.
  final String runType;

  /// The run type's colour; the whole screen is flooded with it.
  final Color ground;

  /// One line: the session, the goal, or "Just run".
  final String plan;

  /// A second, smaller line: today's target, when there is one.
  final String? target;

  /// An intervals session: its shape drawn big, with [structureLine] under it
  /// ("4 x 4:00 / 3:00 jog").
  final engine.SessionSpec? structure;
  final String? structureLine;

  /// Free and Trail: the last run of this type, "Last free run: 7.2 km ...".
  final String? lastRun;

  /// Text colour on every run type's ground: Night ink, 4.5:1 or better on
  /// each (tested).
  static const Color ink = NightSession.bgBase;

  /// The pre-start GPS probe the Start screen keeps running while this
  /// screen is up (the warm-up: a fix is ready by GO).
  final ValueListenable<GpsProbeEvent?> probe;

  /// Starts the recorder; completes when it has started (true) or failed
  /// (false, the Start screen shows why). [hold] completes when GO has been
  /// on screen long enough to read; the Start screen waits for it before it
  /// swaps to the recording screen. The route is replaced on success.
  final Future<bool> Function(Future<void> hold) onGo;

  /// The timed 5 km and goal runs measure from the first fix, so START
  /// waits for a good one. Every other run may start without.
  final bool requiresGps;

  /// Free and distance-goal runs: show "HOW DO YOU WANT TO RUN?" above START.
  /// A tap saves to settings at once; the Start screen reads it at GO.
  final bool asksCoachChoice;

  /// Back to the picker to change the run. Null hides the link.
  final VoidCallback? onChange;

  /// A fix at this accuracy or better is "good" (same bar as the picker).
  static const double goodAccuracyM = 20;

  /// How long GO stays on screen before the recording screen replaces it.
  static const Duration goHold = Duration(milliseconds: 450);

  @override
  State<ReadyScreen> createState() => _ReadyScreenState();
}

enum _Gps { searching, good, weak }

class _ReadyScreenState extends State<ReadyScreen> with WidgetsBindingObserver {
  /// Null = not counting. 0 = GO.
  int? _count;
  bool _going = false;
  Timer? _timer;
  Timer? _bleTimer;
  BleStatus? _ble;

  static const Color _ink = ReadyScreen.ink;
  static const Color _chipInk = NightSession.inkPrimary;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  bool _bleStarted = false;

  /// Held for [dispose], where the context can no longer be asked.
  RecorderGateway? _rec;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _rec = AppServices.of(context).recorder;
    if (_bleStarted) return;
    _bleStarted = true;
    _readBle();
    _warmVoice();
    _bleTimer = Timer.periodic(const Duration(seconds: 3), (_) => _readBle());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Leaving Ready for any reason but GO lets go of the speech player (GO
    // releases it itself once "go" is said).
    if (!_going) _voice(stop: true);
    _timer?.cancel();
    _bleTimer?.cancel();
    super.dispose();
  }

  /// A countdown never runs behind the lock screen or another app.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _cancel();
  }

  Future<void> _readBle() async {
    try {
      final b = await AppServices.of(context).ble.status();
      if (mounted) setState(() => _ble = b);
    } catch (_) {
      // No strap status is the same as no strap: the chip stays as it was.
    }
  }

  _Gps _gpsOf(GpsProbeEvent? p) {
    if (p == null || !p.fix || p.accuracyM == null) return _Gps.searching;
    return p.accuracyM! <= ReadyScreen.goodAccuracyM ? _Gps.good : _Gps.weak;
  }

  bool get _counting => _count != null;

  /// Countdown voice calls never throw: a failure is the same as no voice.
  void _voice({int? beat, bool stop = false, bool prepare = false}) {
    final rec = _rec;
    if (rec == null) return;
    try {
      final Future<void> call = stop
          ? rec.stopCountdownVoice()
          : prepare
          ? rec.prepareCountdownVoice()
          : rec.speakCountdownBeat(beat!);
      call.catchError((Object _) {});
    } catch (_) {
      // No voice is fine: haptics and numerals carry the countdown.
    }
  }

  bool _voiceOn(AppSettings s) => s.cues && s.countdownSeconds > 0;

  void _warmVoice() {
    if (_voiceOn(AppServices.of(context).settings.settings)) {
      _voice(prepare: true);
    }
  }

  void _beat(int n) {
    final s = AppServices.of(context).settings.settings;
    if (_voiceOn(s)) _voice(beat: n);
    if (!s.haptics) return;
    if (n == 0) {
      HapticFeedback.heavyImpact();
    } else {
      HapticFeedback.mediumImpact();
    }
  }

  void _tapStart() {
    if (_counting || _going) return;
    final secs = AppServices.of(context).settings.settings.countdownSeconds;
    if (secs <= 0) {
      _go();
      return;
    }
    // Voice cues may have been switched on in Settings since Ready opened.
    _warmVoice();
    setState(() => _count = secs);
    _beat(secs);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final n = _count;
      if (n == null || _going) return;
      if (n > 1) {
        setState(() => _count = n - 1);
        _beat(n - 1);
      } else {
        _timer?.cancel();
        _go();
      }
    });
  }

  /// Tap anywhere on the countdown: back to Ready. Too late once GO is up.
  void _cancel() {
    if (_going || !_counting) return;
    _timer?.cancel();
    _timer = null;
    _voice(stop: true);
    if (mounted) setState(() => _count = null);
  }

  Future<void> _go() async {
    if (_going) return;
    setState(() {
      _going = true;
      _count = 0;
    });
    _beat(0);
    final ok = await widget.onGo(Future<void>.delayed(ReadyScreen.goHold));
    if (!mounted) return;
    if (!ok) {
      // The Start screen has the reason (permission, storage ...).
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = AppServices.of(context);
    // Settings (opened from the chips below) change what the chips say.
    return ListenableBuilder(
      listenable: services.settings,
      builder: (context, _) => _scaffold(services.settings.settings),
    );
  }

  Widget _scaffold(AppSettings s) {
    final reduced = s.reducedMotion || MediaQuery.of(context).disableAnimations;
    return PopScope(
      canPop: !_counting || _going,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: Scaffold(
        backgroundColor: widget.ground,
        body: _counting ? _countdown(reduced) : _ready(s),
      ),
    );
  }

  // ---- Ready ----

  Widget _ready(AppSettings s) {
    // At large text nothing fits one screen: the whole page scrolls (START
    // included) rather than clip. Otherwise the run's words scroll alone.
    final big = MediaQuery.textScalerOf(context).scale(10) > 12;
    final compact = widget.asksCoachChoice;
    final page = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _readyChildren(s, big: big, compact: compact),
    );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Space.screenGutter,
          Space.x4,
          Space.screenGutter,
          Space.x24,
        ),
        child: big ? SingleChildScrollView(child: page) : page,
      ),
    );
  }

  List<Widget> _readyChildren(
    AppSettings s, {
    required bool big,
    required bool compact,
  }) {
    // Compact (the choice row is shown): the plan and target lines stay
    // outside the scroll area so they are never pushed off a 640 dp screen.
    final pinned = compact && !big;
    final planLines = <Widget>[
      const SizedBox(height: Space.x12),
      Text(
        widget.plan,
        key: const ValueKey('ready-plan'),
        maxLines: pinned ? 1 : 2,
        overflow: TextOverflow.ellipsis,
        style: RunSoloType.body17.copyWith(
          color: _ink,
          fontWeight: FontWeight.w700,
        ),
      ),
      if (widget.target != null) ...[
        const SizedBox(height: Space.x4),
        Text(
          widget.target!,
          key: const ValueKey('ready-target'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: RunSoloType.body15.copyWith(color: _ink),
        ),
      ],
    ];
    final words = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: Space.x8),
        Text(
          'READY?',
          style: RunSoloType.heading26.copyWith(
            color: _ink.withValues(alpha: 0.7),
            letterSpacing: 4,
          ),
        ),
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: compact ? 60 : double.infinity,
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              widget.runType,
              key: const ValueKey('ready-run-type'),
              maxLines: 1,
              style: RunSoloType.display96.copyWith(color: _ink),
            ),
          ),
        ),
        if (!pinned) ...planLines,
        const SizedBox(height: Space.x12),
        if (widget.structure != null) _structureBlock(),
        if (widget.lastRun != null)
          Text(
            widget.lastRun!,
            key: const ValueKey('ready-last-run'),
            style: RunSoloType.body15.copyWith(color: _ink),
          ),
      ],
    );
    final onChips = [
      _OnChip(
        key: const ValueKey('ready-on-voice'),
        label: 'VOICE CUES ${s.cues ? 'ON' : 'OFF'}',
        onTap: _openSettings,
        shrink: compact,
      ),
      _OnChip(
        key: const ValueKey('ready-on-countdown'),
        label:
            'COUNTDOWN ${s.countdownSeconds == 0 ? 'OFF' : '${s.countdownSeconds} S'}',
        onTap: _openSettings,
        shrink: compact,
      ),
      _OnChip(
        key: const ValueKey('ready-on-autopause'),
        label: 'AUTO-PAUSE ${s.autoPause ? 'ON' : 'OFF'}',
        onTap: _openSettings,
        shrink: compact,
      ),
    ];
    return [
      Row(
        children: [
          IconButton(
            key: const ValueKey('ready-back'),
            tooltip: 'Back',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 48, height: 48),
            icon: const Icon(Icons.arrow_back, color: _ink),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const Spacer(),
          if (widget.onChange != null)
            TextButton(
              key: const ValueKey('ready-change'),
              onPressed: widget.onChange,
              style: TextButton.styleFrom(foregroundColor: _ink),
              child: Text(
                'CHANGE',
                style: RunSoloType.heading19.copyWith(color: _ink),
              ),
            ),
        ],
      ),
      big ? words : Expanded(child: SingleChildScrollView(child: words)),
      if (pinned) ...[const SizedBox(height: Space.x8), ...planLines],
      const SizedBox(height: Space.x8),
      if (widget.asksCoachChoice) ...[
        CoachChoiceRow(
          selected: s.coachChoice,
          onGround: (ink: _ink, onInk: _chipInk),
          onSelect: _pickChoice,
        ),
        const SizedBox(height: Space.x12),
      ],
      // At large text on a small phone the chips give way so START stays on
      // the first screen; the same settings sit one tap away in Settings.
      if (big && compact)
        const SizedBox.shrink()
      else if (compact)
        Row(
          children: [
            for (final (i, c) in onChips.indexed) ...[
              if (i > 0) const SizedBox(width: Space.x8),
              Expanded(child: c),
            ],
          ],
        )
      else
        Wrap(spacing: Space.x8, runSpacing: Space.x8, children: onChips),
      const SizedBox(height: Space.x12),
      ValueListenableBuilder<GpsProbeEvent?>(
        valueListenable: widget.probe,
        builder: (context, probe, _) {
          final gps = _gpsOf(probe);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Chip(
                key: const ValueKey('ready-gps'),
                label: 'GPS',
                value: switch (gps) {
                  _Gps.searching =>
                    widget.requiresGps ? 'WAITING' : 'SEARCHING',
                  _Gps.good => 'GOOD',
                  _Gps.weak => 'WEAK',
                },
                dot: gps == _Gps.good
                    ? NightSession.semImproving
                    : NightSession.semWarn,
              ),
              if (HostCaps.strapPairing) ...[
                const SizedBox(height: Space.x8),
                _strapChip(s),
              ],
              const SizedBox(height: Space.x12),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 20),
                child: gps == _Gps.good
                    ? null
                    : Text(
                        widget.requiresGps
                            ? 'Waiting for a good GPS fix'
                            : 'Starting without a good GPS fix',
                        key: const ValueKey('ready-gps-warning'),
                        style: RunSoloType.body15.copyWith(
                          color: _ink,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
              const SizedBox(height: Space.x8),
              FilledButton(
                key: const ValueKey('ready-start'),
                onPressed: widget.requiresGps && gps != _Gps.good
                    ? null
                    : _tapStart,
                style: FilledButton.styleFrom(
                  backgroundColor: _ink,
                  foregroundColor: _chipInk,
                  disabledBackgroundColor: _ink.withValues(alpha: 0.4),
                  disabledForegroundColor: _chipInk.withValues(alpha: 0.6),
                  minimumSize: Size.fromHeight(compact ? (big ? 72 : 88) : 104),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(Radii.card),
                  ),
                  textStyle: RunSoloType.display96,
                ),
                child: const CapsText('START'),
              ),
            ],
          );
        },
      ),
    ];
  }

  void _pickChoice(engine.CoachChoice c) {
    AppServices.of(context).settings.update((x) => x.copyWith(coachChoice: c));
  }

  void _openSettings() => Navigator.of(context).pushNamed(Routes.settings);

  /// The session's shape as big blocks, and its words under it.
  Widget _structureBlock() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        padding: const EdgeInsets.all(Space.x12),
        decoration: BoxDecoration(
          color: NightSession.bgBase.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(Radii.card),
        ),
        child: StructureGlyph(
          key: const ValueKey('ready-structure'),
          spec: widget.structure!,
          height: 48,
        ),
      ),
      if (widget.structureLine != null) ...[
        const SizedBox(height: Space.x8),
        Text(
          widget.structureLine!,
          key: const ValueKey('ready-structure-line'),
          style: RunSoloType.heading26.copyWith(color: _ink),
        ),
      ],
    ],
  );

  Widget _strapChip(AppSettings s) {
    final saved = s.strap;
    final connected = saved != null && (_ble?.connected ?? false);
    final hr = _ble?.lastHr;
    return _Chip(
      key: const ValueKey('ready-strap'),
      label: connected ? 'STRAP CONNECTED' : 'HR STRAP',
      // The reading is as big as GPS's GOOD.
      value: saved == null
          ? 'NONE'
          : connected
          ? (hr == null ? 'NO READING' : '$hr BPM')
          : 'CONNECTING',
      dot: saved == null
          ? NightSession.inkMuted
          : connected
          ? NightSession.semImproving
          : NightSession.semWarn,
    );
  }

  // ---- Countdown ----

  Widget _countdown(bool reduced) {
    final n = _count!;
    final word = n == 0 ? 'GO' : '$n';
    // One huge word, dark on the run type's colour. The size is a fraction
    // of the screen so 10 and GO fit as well as 3.
    final numeral = FittedBox(
      fit: BoxFit.scaleDown,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.screenGutter),
        child: Text(
          word,
          key: const ValueKey('countdown-word'),
          maxLines: 1,
          style: RunSoloType.display96.copyWith(
            color: _ink,
            fontSize: 360,
            height: 1.0,
          ),
        ),
      ),
    );
    return GestureDetector(
      key: const ValueKey('countdown'),
      behavior: HitTestBehavior.opaque,
      onTap: _cancel,
      child: Semantics(
        liveRegion: true,
        label: n == 0 ? 'Go' : '$n',
        child: SafeArea(
          child: Stack(
            children: [
              Center(
                child: reduced
                    ? numeral
                    : TweenAnimationBuilder<double>(
                        key: ValueKey('beat-$n'),
                        tween: Tween(begin: 0, end: 1),
                        duration: MotionDurations.slow,
                        curve: MotionCurves.emphasized,
                        builder: (context, v, child) => Opacity(
                          opacity: v.clamp(0.0, 1.0),
                          child: Transform.scale(
                            scale: 1.6 - 0.6 * v,
                            child: child,
                          ),
                        ),
                        child: numeral,
                      ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: Space.x24,
                child: Text(
                  n == 0 ? '' : 'Tap anywhere to cancel',
                  textAlign: TextAlign.center,
                  style: RunSoloType.body17.copyWith(
                    color: _ink,
                    fontWeight: FontWeight.w700,
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

/// A big live check: dot + what, and its state in display type.
class _Chip extends StatelessWidget {
  const _Chip({
    super.key,
    required this.label,
    required this.value,
    required this.dot,
  });

  final String label;
  final String value;
  final Color dot;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label $value',
      excludeSemantics: true,
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: Space.x16),
        decoration: BoxDecoration(
          color: NightSession.bgBase,
          borderRadius: BorderRadius.circular(Radii.button),
        ),
        child: Row(
          children: [
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: Space.x12),
            Text(
              label,
              style: RunSoloType.runLabel.copyWith(
                color: NightSession.inkSecondary,
              ),
            ),
            const Spacer(),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text(
                  value,
                  maxLines: 1,
                  style: RunSoloType.title28.copyWith(
                    color: NightSession.inkPrimary,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One thing that is on for this run; tap to change it in Settings.
class _OnChip extends StatelessWidget {
  const _OnChip({
    super.key,
    required this.label,
    required this.onTap,
    this.shrink = false,
  });

  final bool shrink;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      label,
      maxLines: 1,
      style: RunSoloType.label13.copyWith(
        fontSize: 13,
        color: ReadyScreen.ink,
        fontWeight: FontWeight.w700,
      ),
    );
    return Semantics(
      button: true,
      label: '$label. Opens Settings.',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.pill),
        child: Container(
          // Sized by its words (a Container with an alignment would fill
          // the row); 13 sp text plus this padding is a 44 dp target.
          alignment: shrink ? Alignment.center : null,
          padding: EdgeInsets.symmetric(
            horizontal: shrink ? Space.x8 : Space.x12,
            vertical: 12,
          ),
          decoration: BoxDecoration(
            border: Border.all(color: ReadyScreen.ink, width: 2),
            borderRadius: BorderRadius.circular(Radii.pill),
          ),
          // 12 sp at least, never scaled down: a chip that does not fit
          // wraps to a second row instead.
          child: shrink ? FittedBox(fit: BoxFit.scaleDown, child: text) : text,
        ),
      ),
    );
  }
}
