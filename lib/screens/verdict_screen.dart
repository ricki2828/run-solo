import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../app/routes.dart';
import '../app/services.dart';
import '../platform/gateway.dart';
import '../state/history_store.dart';
import '../state/max_hr.dart';
import '../theme/theme.dart';
import '../widgets/chrome.dart';
import '../widgets/delta_glyph.dart';
import '../widgets/rep_bars.dart';
import 'run_detail_screen.dart';

/// Post-run screen (design brief §4.6). A 4x4 gets the verdict with the M4
/// reveal; a Laps or Free run gets its summary (no verdict word, plan
/// §18.2). Opened right after Stop and from History rows.
///
/// M4 is Flutter-authored for now (one `AnimationController`, intervals per
/// beat); the Rive file replaces the middle beats when the founder has
/// iterated the timing. Reduced motion: end state, 160 ms fade.
class VerdictScreen extends StatefulWidget {
  const VerdictScreen({
    super.key,
    required this.runId,
    this.justFinished = false,
  });
  final String runId;

  /// Opened from Stop: fold this run's observed max HR into settings and show
  /// "Done" instead of a back arrow.
  final bool justFinished;

  @override
  State<VerdictScreen> createState() => _VerdictScreenState();
}

class _VerdictScreenState extends State<VerdictScreen> {
  Future<(RunDetail?, RunSummary?)>? _load;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load ??= _loadDetail();
  }

  Future<(RunDetail?, RunSummary?)> _loadDetail() async {
    final services = AppServices.of(context);
    final detail = await services.history.load(widget.runId);
    if (detail == null) return (null, null);
    final all = await services.history.list();
    final previous = previousFourByFour(all, detail.summary);
    // Fold on every load, not only right after Stop: the guard ignores
    // anything at or below the stored value, so this is idempotent, and a
    // run whose verdict screen never opened (app died after Stop) still
    // folds the next time it is viewed.
    final observed =
        detail.analysis.intervals?.observedMaxHrThisRun ??
        detail.analysis.laps?.observedMaxHrThisRun;
    if (observed != null) {
      await services.settings.update(
        (s) => MaxHr.foldObserved(s, observed, detail.run.end),
      );
    }
    return (detail, previous);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return FutureBuilder<(RunDetail?, RunSummary?)>(
      future: _load,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Scaffold(body: SizedBox.shrink());
        }
        final (detail, previous) = snap.data!;
        if (detail == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('RUN')),
            body: Padding(
              padding: const EdgeInsets.all(Space.screenGutter),
              child: Text(
                'This run could not be read. Its file may be missing.',
                style: RunSoloType.body17.copyWith(color: t.inkSecondary),
              ),
            ),
          );
        }
        return switch (detail.summary.mode) {
          RecordMode.intervals => _FourByFourVerdict(
            detail: detail,
            previous: previous,
            justFinished: widget.justFinished,
          ),
          RecordMode.laps || RecordMode.free || RecordMode.cooper =>
            _SummaryScreen(detail: detail, justFinished: widget.justFinished),
        };
      },
    );
  }
}

/// The nearest earlier Intervals run of the same comparison key (plan
/// §3.7: like with like) with metrics, for the ghost bars.
RunSummary? previousFourByFour(List<RunSummary> all, RunSummary current) {
  final key = current.comparisonKey ?? current.spec?.comparisonKey;
  for (final r in all) {
    if (r.id == current.id) continue;
    if (!r.start.isBefore(current.start)) continue;
    if (!r.isFourByFour || !r.hasIntervals) continue;
    final k = r.comparisonKey ?? r.spec?.comparisonKey;
    if (key == null || k == null || k == key) return r;
  }
  return null;
}

/// Which M4 branch a verdict takes (design brief §3 M4 `state` input).
enum RevealState { baseline, faster, holding, slower, noise, none }

RevealState revealStateOf(engine.Verdict? v) {
  if (v == null) return RevealState.none;
  return switch (v.headline) {
    engine.VerdictHeadline.faster => RevealState.faster,
    engine.VerdictHeadline.holding => RevealState.holding,
    engine.VerdictHeadline.slower => RevealState.slower,
    engine.VerdictHeadline.noRealChange => RevealState.noise,
    engine.VerdictHeadline.baselineSet => RevealState.baseline,
    engine.VerdictHeadline.noVerdict ||
    engine.VerdictHeadline.indoorRun => RevealState.none,
  };
}

/// Rep rows for the bars: this run's reps against the previous run's.
List<RepBarDatum> repBarData(RunDetail detail, RunSummary? previous) {
  final m = detail.analysis.intervals;
  if (m == null) return const [];
  final ghost = previous?.repPacesSecPerKm;
  return [
    for (final r in m.reps)
      RepBarDatum(
        label: 'Rep ${r.number}',
        paceSecPerKm: r.paceSecPerKm,
        repMetres: m.kind == engine.IntervalMetricKind.repTime
            ? m.nominalRepMetres
            : null,
        ghostSecPerKm: ghost != null && r.number - 1 < ghost.length
            ? ghost[r.number - 1]
            : null,
        excluded: !r.clean,
        reason: r.dropped
            ? 'dropped'
            : switch (r.interruptReason) {
                engine.InterruptReason.gpsDropped => 'GPS dropped',
                engine.InterruptReason.paused => 'paused',
                engine.InterruptReason.recordingStopped => 'recording stopped',
                null => null,
              },
      ),
  ];
}

class _FourByFourVerdict extends StatefulWidget {
  const _FourByFourVerdict({
    required this.detail,
    required this.previous,
    required this.justFinished,
  });
  final RunDetail detail;
  final RunSummary? previous;
  final bool justFinished;

  @override
  State<_FourByFourVerdict> createState() => _FourByFourVerdictState();
}

class _FourByFourVerdictState extends State<_FourByFourVerdict>
    with SingleTickerProviderStateMixin {
  // M4 beats on a 1640 ms timeline (1400 reveal + 240 subline fade).
  static const int _totalMs = 1640;
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: _totalMs),
  );
  late final Animation<double> _bars = _beat(0, 300);
  late final Animation<double> _slope = _beat(300, 700);
  late final Animation<double> _word = _beat(700, 960, MotionCurves.emphasized);
  late final Animation<double> _bloom = _beat(960, 1360);
  late final Animation<double> _lines = _beat(1400, 1640);
  bool _hapticsFired = false;

  Animation<double> _beat(int from, int to, [Curve curve = Curves.linear]) =>
      CurvedAnimation(
        parent: _reveal,
        curve: Interval(from / _totalMs, to / _totalMs, curve: curve),
      );

  bool get _reduced =>
      MediaQuery.disableAnimationsOf(context) ||
      AppServices.of(context).settings.settings.reducedMotion;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reveal.isAnimating || _reveal.isCompleted) return;
    if (_reduced) {
      // Static branch: end state, 160 ms fade (design brief §3).
      _reveal.duration = MotionDurations.quick;
      _reveal.forward();
      _fireHaptics();
    } else {
      _reveal.addListener(_onTick);
      _reveal.forward();
    }
  }

  bool _secondPulseFired = false;

  void _onTick() {
    final ms = _reveal.value * _totalMs;
    if (!_hapticsFired && ms >= 960) _fireHaptics();
    // FASTER: heavyImpact ×2, the second one 120 ms later (no Timer, so the
    // widget tree never leaves a pending timer behind).
    if (_hapticsFired && !_secondPulseFired && ms >= 1080) {
      _secondPulseFired = true;
      if (revealStateOf(widget.detail.summary.verdict) == RevealState.faster &&
          AppServices.of(context).settings.settings.haptics) {
        HapticFeedback.heavyImpact();
      }
    }
  }

  void _fireHaptics() {
    _hapticsFired = true;
    if (!AppServices.of(context).settings.settings.haptics) return;
    switch (revealStateOf(widget.detail.summary.verdict)) {
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
    final v = d.summary.verdict;
    final state = revealStateOf(v);
    final reps = repBarData(d, widget.previous);
    final tone = switch (state) {
      RevealState.faster => RepTone.arc,
      RevealState.slower => RepTone.slower,
      _ => RepTone.neutral,
    };
    final flagged = state == RevealState.none;
    final durationMs = d.summary.durationMs;
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Arc bloom: radial, 40 % → 0, settles at 12 % (faster only).
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
                            t.accentArc,
                            t.accentArc.withValues(alpha: 0),
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
                        '${runHeaderTitle(d.summary)} · ${Fmt.dayDate(d.run.start)} · ${Fmt.clock(durationMs)}',
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
                if (reps.isNotEmpty)
                  AnimatedBuilder(
                    animation: _reveal,
                    builder: (context, _) => RepBars(
                      reps: reps,
                      units: units,
                      progress: _bars.value,
                      fadeProgress: flagged ? 0 : _slope.value,
                      tone: _bloom.value > 0 || _reduced
                          ? tone
                          : RepTone.neutral,
                    ),
                  ),
                const SizedBox(height: Space.x24),
                const LapLineDivider(gapAt: 0.18),
                const SizedBox(height: Space.x12),
                // The verdict word wipes upward out of the lap line.
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
                    child: _VerdictWord(
                      text: v?.headline.text ?? 'NO VERDICT',
                      state: state,
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
                  child: _Lines(detail: d, units: units, flagged: flagged),
                ),
                const SizedBox(height: Space.x24),
                if (v != null && v.bestIn365Days)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _ArcChip(label: 'New best'),
                  ),
                const SizedBox(height: Space.x24),
                if (flagged && d.analysis.lapsInconsistent)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.x12),
                    child: FilledButton(
                      key: const ValueKey('fix-laps'),
                      onPressed: () =>
                          Navigator.of(context)
                              .pushNamed(Routes.fixLaps, arguments: d.run.id),
                      child: const Text('FIX LAPS'),
                    ),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: _SecondaryButton(
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
          // 2 % static grain, verdict screen only.
          const IgnorePointer(child: _Grain()),
        ],
      ),
    );
  }
}

class _VerdictWord extends StatelessWidget {
  const _VerdictWord({required this.text, required this.state});
  final String text;
  final RevealState state;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final color = switch (state) {
      RevealState.faster => t.accentArc,
      RevealState.none => t.inkSecondary,
      _ => t.inkPrimary,
    };
    final direction = switch (state) {
      RevealState.faster => DeltaDirection.up,
      RevealState.slower => DeltaDirection.down,
      RevealState.holding || RevealState.noise => DeltaDirection.flat,
      RevealState.baseline || RevealState.none => null,
    };
    return Semantics(
      header: true,
      label: 'Verdict: $text',
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (direction != null) ...[
              DeltaGlyph(
                key: ValueKey('verdict-arrow-${direction.name}'),
                direction: direction,
                color: color,
                size: 40,
              ),
              const SizedBox(width: Space.x12),
            ],
            Text(
              text,
              key: const ValueKey('verdict-word'),
              softWrap: false,
              style: RunSoloType.display96.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

class _Lines extends StatelessWidget {
  const _Lines({
    required this.detail,
    required this.units,
    required this.flagged,
  });
  final RunDetail detail;
  final Units units;
  final bool flagged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final a = detail.analysis;
    final v = detail.summary.verdict;
    final lines = <String>[];
    if (v != null) {
      lines.add(v.subline);
      // I3: "Last time: 4 reps, 3:00 recovery." on its own line (D4).
      if (v.comparisonNote != null) lines.add(v.comparisonNote!);
      if (v.hrLine != null) lines.add(v.hrLine!);
    }
    if (flagged) {
      final why = a.detection?.inconsistencyDetail;
      if (why != null) lines.add(why);
      if (a.lapEditsInvalid) {
        lines.add('Your lap edits no longer fit this run and were ignored.');
      }
    }
    if (a.noisy) lines.add('GPS was too noisy for a pace verdict.');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final l in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.x4),
            child: Text(
              l,
              style: RunSoloType.body17.copyWith(color: t.inkPrimary),
            ),
          ),
      ],
    );
  }
}

class _ArcChip extends StatelessWidget {
  const _ArcChip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Container(
      key: const ValueKey('pb-chip'),
      padding: const EdgeInsets.symmetric(
        horizontal: Space.x16,
        vertical: Space.x8,
      ),
      decoration: BoxDecoration(
        color: t.accentArc,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text(
        label.toUpperCase(),
        style: RunSoloType.label13.copyWith(color: t.accentArcInk),
      ),
    );
  }
}

class _SecondaryButton extends StatelessWidget {
  const _SecondaryButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.button),
        child: Container(
          height: 64,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: t.bgRaised,
            borderRadius: BorderRadius.circular(Radii.button),
            border: Border.all(color: t.lineHair),
          ),
          child: Text(
            label,
            style: RunSoloType.title28.copyWith(color: t.inkPrimary),
          ),
        ),
      ),
    );
  }
}

/// Static 2 % noise (design brief §2.2 texture): a deterministic dot field,
/// no animation, no image asset.
class _Grain extends StatelessWidget {
  const _Grain();

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _GrainPainter());
}

class _GrainPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = const Color(0x05FFFFFF);
    var seed = 12345;
    for (var i = 0; i < 1200; i++) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      final x = (seed % 10007) / 10007 * size.width;
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      final y = (seed % 10007) / 10007 * size.height;
      canvas.drawRect(Rect.fromLTWH(x, y, 1, 1), p);
    }
  }

  @override
  bool shouldRepaint(_GrainPainter old) => false;
}

/// Laps / Free summary after Stop (plan §18.2 post-run column): no verdict
/// word. Reuses the detail body.
class _SummaryScreen extends StatelessWidget {
  const _SummaryScreen({required this.detail, required this.justFinished});
  final RunDetail detail;
  final bool justFinished;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final title = switch (detail.summary.mode) {
      RecordMode.laps
          when detail.summary.spec?.templateId ==
              engine.SessionSpec.fartlekId =>
        'FARTLEK',
      RecordMode.laps => 'LAPS RUN',
      RecordMode.free => 'FREE RUN',
      RecordMode.cooper => '12-MINUTE TEST',
      RecordMode.intervals => 'INTERVALS',
    };
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        automaticallyImplyLeading: !justFinished,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: RunDetailBody(detail: detail, showHeader: true)),
            if (justFinished)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.screenGutter,
                  Space.x12,
                  Space.screenGutter,
                  Space.x24,
                ),
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('DONE'),
                ),
              )
            else
              SizedBox(
                height: Space.x24,
                child: ColoredBox(color: t.bgBase),
              ),
          ],
        ),
      ),
    );
  }
}
