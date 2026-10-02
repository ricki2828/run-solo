import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../app/services.dart';
import '../platform/gateway.dart';
import '../state/history_store.dart';
import '../state/trails.dart';
import '../theme/theme.dart';
import '../widgets/chrome.dart';
import '../widgets/rank_chip.dart';
import 'run_detail_screen.dart';
import 'trail_board_screen.dart';
import 'verdict_screen.dart';

/// Which reveal branch a trail result takes (same colours and haptics as
/// the 4x4 verdict: mint faster, vermillion slower, Bone level).
RevealState trailRevealState(engine.TrailTone tone) => switch (tone) {
  engine.TrailTone.faster => RevealState.faster,
  engine.TrailTone.slower => RevealState.slower,
  engine.TrailTone.same => RevealState.noise,
  engine.TrailTone.baseline => RevealState.baseline,
  engine.TrailTone.none => RevealState.none,
};

/// The Trail result: judged against your earlier runs on the SAME trail when
/// there is a match, else on effort pace against your recent trail runs, with
/// the 4x4 verdict's choreographed reveal (M4: moving time 0-250 ms, word and
/// lines 600-900 ms, a cyan PB chip for the best on the trail). The wording
/// and the matching live in the engine; this lays them out.
class TrailVerdictScreen extends StatefulWidget {
  const TrailVerdictScreen({
    super.key,
    required this.detail,
    required this.all,
    required this.justFinished,
    this.onChanged,
  });
  final RunDetail detail;

  /// Every run, for the earlier trail runs.
  final List<RunSummary> all;
  final bool justFinished;
  final VoidCallback? onChanged;

  @override
  State<TrailVerdictScreen> createState() => _TrailVerdictScreenState();
}

class _TrailVerdictScreenState extends State<TrailVerdictScreen>
    with SingleTickerProviderStateMixin {
  static const int _totalMs = 900;
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: _totalMs),
  );
  late final Animation<double> _hero = _beat(0, 250);
  late final Animation<double> _word = _beat(600, 900, MotionCurves.emphasized);
  late final Animation<double> _bloom = _beat(600, 900);
  late final Animation<double> _lines = _beat(600, 900);
  bool _hapticsFired = false;

  late final engine.TrailRunFacts _facts = trailFactsOfDetail(widget.detail);
  late final engine.TrailResult _result;
  late final engine.TrailGroup? _group;

  Animation<double> _beat(int from, int to, [Curve curve = Curves.linear]) =>
      CurvedAnimation(
        parent: _reveal,
        curve: Interval(from / _totalMs, to / _totalMs, curve: curve),
      );

  bool get _reduced =>
      MediaQuery.disableAnimationsOf(context) ||
      AppServices.of(context).settings.settings.reducedMotion;

  @override
  void initState() {
    super.initState();
    final others = trailFactsOfAll(widget.all);
    // The result is worked out here, not stored: it reads the index, so it
    // always agrees with the trail board.
    _result = engine.TrailVerdict.of(_facts, others);
    final groups = engine.Trails.group([
      for (final o in others)
        if (o.id != _facts.id) o,
      _facts,
    ]);
    _group = engine.Trails.groupOf(_facts.id, groups);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reveal.isAnimating || _reveal.isCompleted) return;
    if (_reduced) {
      _reveal.value = 1;
      _fireHaptics();
    } else {
      _reveal.addListener(_onTick);
      _reveal.forward();
    }
  }

  void _onTick() {
    if (!_hapticsFired && _reveal.value * _totalMs >= 600) _fireHaptics();
  }

  void _fireHaptics() {
    _hapticsFired = true;
    if (!AppServices.of(context).settings.settings.haptics) return;
    switch (trailRevealState(_result.tone)) {
      case RevealState.faster:
        HapticFeedback.heavyImpact();
      case RevealState.slower:
        HapticFeedback.mediumImpact();
      case RevealState.holding:
      case RevealState.noise:
        HapticFeedback.lightImpact();
      case RevealState.baseline:
      case RevealState.none:
        break;
    }
  }

  @override
  void dispose() {
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final services = AppServices.of(context);
    final units = services.settings.settings.units;
    final d = widget.detail;
    final r = _result;
    final state = trailRevealState(r.tone);
    final onTrail = _group != null && _group.runs.length >= 2;

    // "FASTER ON THIS TRAIL": the word big, the place it applies to under it.
    const kicker = ' ON THIS TRAIL';
    final split = r.headline.endsWith(kicker);
    final big = split
        ? r.headline.substring(0, r.headline.length - kicker.length)
        : r.headline;

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (state == RevealState.faster)
            AnimatedBuilder(
              animation: _bloom,
              builder: (context, _) {
                final p = _bloom.value;
                if (p == 0) return const SizedBox.shrink();
                return IgnorePointer(
                  child: Opacity(
                    opacity: 0.4 - 0.28 * p,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: const Alignment(0, 0.15),
                          radius: 0.2 + 1.2 * p,
                          colors: [
                            NightSession.semImproving,
                            NightSession.semImproving.withValues(alpha: 0),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          SafeArea(
            child: ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.screenGutter,
              ),
              children: [
                const SizedBox(height: Space.x16),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'TRAIL RUN · ${Fmt.dayDate(d.run.start)} · '
                        '${Fmt.clock(d.summary.durationMs)}',
                        style: RunSoloType.label13.copyWith(
                          color: t.inkSecondary,
                        ),
                      ),
                    ),
                    if (!widget.justFinished)
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                        tooltip: 'Close',
                        iconSize: 24,
                        constraints: const BoxConstraints(
                          minWidth: 56,
                          minHeight: 56,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: Space.x24),
                FadeTransition(
                  opacity: _hero,
                  child: _Hero(facts: _facts, units: units),
                ),
                const SizedBox(height: Space.x24),
                const LapLineDivider(gapAt: 0.18),
                const SizedBox(height: Space.x12),
                ClipRect(
                  child: AnimatedBuilder(
                    animation: _word,
                    builder: (context, child) => Transform.translate(
                      offset: Offset(0, 96 * (1 - _word.value)),
                      child: Opacity(
                        opacity: _word.value.clamp(0, 1),
                        child: child,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        VerdictWord(text: big, state: state),
                        if (split)
                          Padding(
                            padding: const EdgeInsets.only(top: Space.x4),
                            child: Text(
                              kicker.trim(),
                              key: const ValueKey('trail-verdict-kicker'),
                              style: RunSoloType.title28.copyWith(
                                color: _toneColor(t, state),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: Space.x12),
                AnimatedBuilder(
                  animation: _lines,
                  builder: (context, child) => Transform.translate(
                    offset: Offset(0, 12 * (1 - _lines.value)),
                    child: Opacity(
                      opacity: _lines.value.clamp(0, 1),
                      child: child,
                    ),
                  ),
                  child: Column(
                    key: const ValueKey('trail-verdict-lines'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: Space.x8),
                        child: Text(
                          r.subline,
                          key: const ValueKey('trail-verdict-subline'),
                          style: RunSoloType.body17.copyWith(
                            color: t.inkPrimary,
                          ),
                        ),
                      ),
                      for (final l in r.lines)
                        Padding(
                          padding: const EdgeInsets.only(bottom: Space.x4),
                          child: Text(
                            l,
                            style: RunSoloType.body15.copyWith(
                              color: t.inkSecondary,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: Space.x16),
                if (r.isTrailBest)
                  RankChip(
                    label: 'Best on ${r.trailName}',
                    pb: true,
                    celebrate: widget.justFinished,
                    haptics: services.settings.settings.haptics,
                  ),
                if (onTrail)
                  RankChip(
                    key: const ValueKey('trail-board-chip'),
                    label: '${_group.name} board',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => TrailBoardScreen(trailKey: _group.key),
                      ),
                    ),
                  ),
                const SizedBox(height: Space.x24),
                Row(
                  children: [
                    Expanded(
                      child: VerdictSecondaryButton(
                        label: 'DETAILS',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => RunDetailScreen(runId: d.run.id),
                          ),
                        ),
                      ),
                    ),
                    if (widget.justFinished) ...[
                      const SizedBox(width: Space.x12),
                      Expanded(
                        child: FilledButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('DONE'),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: Space.x24),
              ],
            ),
          ),
          const IgnorePointer(child: VerdictGrain()),
        ],
      ),
    );
  }
}

Color _toneColor(RunSoloTokens t, RevealState state) => switch (state) {
  RevealState.faster => NightSession.semImproving,
  RevealState.slower => t.semSlower,
  RevealState.none => t.inkSecondary,
  _ => t.inkPrimary,
};

/// The run's moving time, big, with distance and climb under it.
class _Hero extends StatelessWidget {
  const _Hero({required this.facts, required this.units});
  final engine.TrailRunFacts facts;
  final Units units;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final climb = facts.climbM == null
        ? ''
        : ' · ${Fmt.elevation(facts.climbM, units)} climb';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            Fmt.clock(facts.movingMs),
            key: const ValueKey('trail-verdict-moving'),
            softWrap: false,
            style: RunSoloType.display96.copyWith(color: t.inkPrimary),
          ),
        ),
        Text(
          'MOVING TIME',
          style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
        ),
        const SizedBox(height: Space.x4),
        Text(
          '${Fmt.distance(facts.distanceM, units)}$climb',
          style: RunSoloType.body17.copyWith(color: t.inkPrimary),
        ),
      ],
    );
  }
}
