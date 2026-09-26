import 'dart:async';

import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/services.dart';
import '../platform/gateway.dart';
import '../state/coaching.dart';
import '../state/history_store.dart';
import '../state/sessions.dart';
import '../state/settings.dart';
import '../theme/theme.dart';

/// Loads the coaching fold and folds again each time a background batch
/// lands (a just-finished run gets its derived data a moment later).
mixin _CoachingFold<T extends StatefulWidget> on State<T> {
  Coaching? coaching;
  HistoryStore? _history;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_history != null) return;
    _history = AppServices.of(context).history;
    _history!.derivedChanged.addListener(_fold);
    unawaited(_fold());
  }

  Future<void> _fold() async {
    final history = _history;
    if (history == null) return;
    final c = await history.coaching();
    if (mounted) setState(() => coaching = c);
  }

  @override
  void dispose() {
    _history?.derivedChanged.removeListener(_fold);
    super.dispose();
  }
}

/// "Next time: try one fewer rep, …": the suggestion as the section's last
/// line (A10.6).
String nextTimeLine(engine.CoachSuggestion s) =>
    'Next time: ${s.text[0].toLowerCase()}${s.text.substring(1)}';

/// A10.6: FROM THIS RUN, below Details on the result and after the header
/// on run detail. At most one observation and one suggestion; nothing at
/// all (no heading) when the engine has nothing to say. Advice, not a
/// result: no Arc, no verdict colours, no arrows.
class CoachingSection extends StatefulWidget {
  const CoachingSection({
    super.key,
    required this.runId,
    this.padding = const EdgeInsets.only(bottom: Space.x24),
  });
  final String runId;

  /// Space around the section, only when it shows (no gap otherwise, so
  /// a screen without coaching looks as before).
  final EdgeInsets padding;

  @override
  State<CoachingSection> createState() => _CoachingSectionState();
}

class _CoachingSectionState extends State<CoachingSection>
    with _CoachingFold<CoachingSection> {
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final report = coaching?.reportFor(widget.runId);
    final o = report?.observation;
    final s = report?.suggestion;
    if (o == null && s == null) return const SizedBox.shrink();
    final settings = AppServices.of(context).settings.settings;
    final onHome =
        s != null &&
        coaching!.tryNext(dismissedRunId: settings.tryNextDismissed)?.runId ==
            widget.runId;
    return Padding(
      padding: widget.padding,
      child: Column(
        key: const ValueKey('coaching'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'FROM THIS RUN',
            style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
          ),
          const SizedBox(height: Space.x8),
          if (o != null)
            Text(
              o.text,
              key: const ValueKey('coaching-observation'),
              // The research norm is context, not the runner's own number.
              style: o.researchBased
                  ? RunSoloType.body15.copyWith(color: t.inkSecondary)
                  : RunSoloType.body17.copyWith(color: t.inkPrimary),
            ),
          if (s != null) ...[
            if (o != null) const SizedBox(height: Space.x8),
            Text(
              onHome ? '${nextTimeLine(s)} Saved to Home.' : nextTimeLine(s),
              key: const ValueKey('coaching-suggestion'),
              style: RunSoloType.body15.copyWith(color: t.inkPrimary),
            ),
          ],
        ],
      ),
    );
  }
}

/// "Set it up" (A10.4): the settings change that puts the suggested session
/// on Start, or null when it maps to none (the Zone 2 run, a custom
/// session's key).
AppSettings Function(AppSettings)? tryNextSetUp(TryNext next) {
  final s = next.suggestion;
  switch (s.kind) {
    case engine.SuggestionKind.zone2LongRun:
      return null;
    case engine.SuggestionKind.norwegian4x4:
      return (x) => x.copyWith(
        lastMode: RecordMode.intervals,
        sessionId: engine.SessionSpec.norwegian4x4Id,
        goalRun: false,
      );
    case engine.SuggestionKind.fewerReps:
      final p = s.key == null
          ? null
          : engine.SessionCatalogue.ownerOfKey(s.key!);
      if (p == null) return null;
      if (p.id == engine.SessionSpec.norwegian4x4Id) {
        return (x) => x.copyWith(
          lastMode: RecordMode.intervals,
          sessionId: p.id,
          goalRun: false,
          reps: PresetRules.clampReps(x.reps - 1),
        );
      }
      final min = p.minReps;
      if (min == null) return null;
      return (x) {
        final old = x.presetEdits[p.id];
        final reps = ((old?.reps ?? p.defaultReps) - 1).clamp(min, p.maxReps!);
        return x.copyWith(
          lastMode: RecordMode.intervals,
          sessionId: p.id,
          goalRun: false,
          presetEdits: {
            ...x.presetEdits,
            p.id: PresetEdit(reps: reps, recovery: old?.recovery),
          },
        );
      };
  }
}

/// A10.4: TRY NEXT on Home. One card at most, the latest suggestion, gone
/// once dismissed or once the suggested session type has been run. Never
/// a schedule, never a streak, never red. [onSetUp] is offered only when
/// the suggestion maps to a session.
class TryNextCard extends StatefulWidget {
  const TryNextCard({super.key, required this.onSetUp});

  /// Applies [tryNextSetUp]'s change and opens Start. "Set it up" shows only
  /// when the suggestion maps to a session.
  final Future<void> Function(AppSettings Function(AppSettings) change) onSetUp;

  @override
  State<TryNextCard> createState() => _TryNextCardState();
}

class _TryNextCardState extends State<TryNextCard>
    with _CoachingFold<TryNextCard> {
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final services = AppServices.of(context);
    final next = coaching?.tryNext(
      dismissedRunId: services.settings.settings.tryNextDismissed,
    );
    if (next == null) return const SizedBox.shrink();
    final setUp = tryNextSetUp(next);
    return Padding(
      padding: const EdgeInsets.only(top: Space.x24),
      child: Container(
        key: const ValueKey('try-next'),
        padding: const EdgeInsets.fromLTRB(
          Space.x16,
          Space.x4,
          Space.x4,
          Space.x16,
        ),
        decoration: BoxDecoration(
          color: t.bgRaised,
          borderRadius: BorderRadius.circular(Radii.card),
          border: Border.all(color: t.lineHair),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'TRY NEXT',
                    style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
                  ),
                ),
                IconButton(
                  key: const ValueKey('try-next-dismiss'),
                  tooltip: 'Dismiss',
                  constraints: const BoxConstraints(
                    minWidth: 56,
                    minHeight: 56,
                  ),
                  icon: Icon(Icons.close, color: t.inkSecondary),
                  onPressed: () => services.settings.update(
                    (s) => s.copyWith(tryNextDismissed: next.runId),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: Space.x12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    next.suggestion.text,
                    style: RunSoloType.body17.copyWith(color: t.inkPrimary),
                  ),
                  const SizedBox(height: Space.x8),
                  Text(
                    next.reason,
                    style: RunSoloType.body15.copyWith(color: t.inkSecondary),
                  ),
                ],
              ),
            ),
            if (setUp != null)
              TextButton(
                key: const ValueKey('try-next-set-up'),
                style: TextButton.styleFrom(
                  minimumSize: const Size(56, 48),
                  padding: EdgeInsets.zero,
                ),
                onPressed: () => widget.onSetUp(setUp),
                child: Text(
                  'Set it up ›',
                  style: RunSoloType.body15.copyWith(color: t.inkPrimary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
