/// The live "you vs you" context for a Start (Phase 4 plan §3.2, LC1).
///
/// Built from `index.json` (W5b) and each entry's derived data (LB2), never
/// from run files. The expensive part (reading and decoding the index into
/// candidates) is [LiveContextSource.prepare]d ahead, off the UI isolate:
/// when the Start screen opens and whenever the index has changed. Start
/// itself only plans over the candidates it has (the last prepare's, even
/// if the index moved since), inside a 150 ms budget (WARN-3); never
/// prepared, a timeout, an empty plan or any error: the answer is null: Start goes ahead with no compare,
/// no overlay and nothing said (#59 review P2).
///
/// Off by default ([kLiveCompare]): comparisons fire only once the in-app
/// mute (LV2) ships in the same build, because Laps and Intervals runs have
/// no room for a "Mute tips" notification action (#48 review).
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/event_names.dart';
import '../app/perf_diagnostics.dart';
import '../platform/gateway.dart';
import '../platform/session_codec.dart';
import 'history_store.dart' show runModeOf;
import 'run_index.dart';

/// `--dart-define=LIVE_COMPARE=true` turns the live compare on. Default off
/// until LV2 (in-app mute) merges.
const bool kLiveCompare = bool.fromEnvironment('LIVE_COMPARE');

class LiveContextSource {
  LiveContextSource({
    required this.indexFile,
    this.budget = const Duration(milliseconds: 150),
    this.names = kEventNames,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  /// Test seam: a source already prepared over [candidates] (no index).
  @visibleForTesting
  LiveContextSource.prepared(
    List<engine.LiveCandidate> candidates, {
    this.names = kEventNames,
    DateTime Function()? now,
  }) : indexFile = File('/nonexistent/index.json'),
       budget = const Duration(milliseconds: 150),
       now = now ?? DateTime.now {
    _cached = candidates;
    _cachedVersion = _preparedForTest;
  }

  static const String _preparedForTest = 'prepared';

  final File indexFile;
  final Duration budget;
  final engine.EventNames names;
  final DateTime Function() now;

  String? _cachedVersion;
  List<engine.LiveCandidate> _cached = const [];
  Future<void>? _preparing;

  /// Reads the index into candidates in a background isolate when it has
  /// changed since the last prepare. Call when Start opens; cheap when
  /// nothing changed (one stat). Never throws.
  Future<void> prepare() => _cachedVersion == _preparedForTest
      ? Future<void>.value()
      : _preparing ??= _prepare().whenComplete(() => _preparing = null);

  Future<void> _prepare() async {
    try {
      final version = await _versionOf(indexFile);
      if (version == null || version == _cachedVersion) return;
      final path = indexFile.path;
      final sw = Stopwatch()..start();
      final (candidates, runs) = await Isolate.run(() => _candidatesAt(path));
      if (kPerfDiagnostics) {
        PerfDiagnostics.instance.recordPrepare(sw.elapsed, runs);
      }
      _cached = candidates;
      _cachedVersion = version;
    } catch (e) {
      debugPrint('live: prepare failed ($e)');
    }
  }

  static Future<String?> _versionOf(File f) async {
    final stat = await f.stat();
    if (stat.type == FileSystemEntityType.notFound) return null;
    return '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
  }

  /// Runs in the background isolate: the candidates and how many runs the
  /// index holds.
  static (List<engine.LiveCandidate>, int) _candidatesAt(String path) {
    final f = File(path);
    final index = RunIndex.decode(f.existsSync() ? f.readAsStringSync() : null);
    return (
      [for (final e in index.entries.values) ?e.liveCandidate()],
      index.entries.length,
    );
  }

  /// Test seam: runs inside the budget before the fold (a slow index).
  @visibleForTesting
  Future<void> Function()? beforeFold;

  /// The context for a Start of [mode] with [spec] (and [courseKey] for the
  /// Saturday 5 km when the app knows it), or null. Never throws, never
  /// waits longer than [budget]. [preferAlternative]: the runner tapped
  /// the Start target over to its other choice (A10.10, "your PB" vs
  /// predicted), so that one is raced; ignored when there is none.
  /// [coachingMuted]: Settings has Coaching tips (or voice cues) off, so
  /// compares only feed the card.
  Future<LiveContext?> build({
    required RecordMode mode,
    SessionSpec? spec,
    String? courseKey,
    bool preferAlternative = false,
    bool coachingMuted = false,
  }) async {
    final sw = Stopwatch()..start();
    try {
      final ctx = await _build(
        mode,
        spec,
        courseKey,
        preferAlternative,
        coachingMuted,
      ).timeout(budget);
      if (kPerfDiagnostics) PerfDiagnostics.instance.recordBuild(sw.elapsed);
      return ctx;
    } on TimeoutException {
      debugPrint('live: context over ${budget.inMilliseconds} ms, none');
      if (kPerfDiagnostics) {
        PerfDiagnostics.instance.recordBuild(
          sw.elapsed,
          outcome: BuildOutcome.timedOut,
        );
      }
      return null;
    } catch (e) {
      debugPrint('live: no context ($e)');
      if (kPerfDiagnostics) {
        PerfDiagnostics.instance.recordBuild(
          sw.elapsed,
          outcome: BuildOutcome.failed,
        );
      }
      return null;
    }
  }

  Future<LiveContext?> _build(
    RecordMode mode,
    SessionSpec? spec,
    String? courseKey,
    bool preferAlternative,
    bool coachingMuted,
  ) async {
    final version = _cachedVersion == _preparedForTest
        ? _preparedForTest
        : await _versionOf(indexFile);
    if (version == null) return null;
    if (version != _cachedVersion) {
      // Never decode on the UI isolate at Start. The index moved since the
      // last prepare (a derived batch landing after Start opened): race the
      // candidates we have, refresh for next time; never prepared: none.
      unawaited(prepare());
      if (_cachedVersion == null) return null;
    }
    await beforeFold?.call();
    final session = spec?.toEngine();
    final plan = engine.LivePlanner.plan(
      mode: runModeOf(mode),
      session: session,
      courseKey: courseKey,
      runs: _cached,
      names: names,
    );
    // PD2: the event or a goal races its target even before any board has
    // two entries.
    final shown = engine.StartTarget.forSession(
      session,
      runs: _cached,
      now: now(),
      names: names,
      courseKey: courseKey,
    );
    final target = preferAlternative ? shown?.alternative ?? shown : shown;
    if (plan.isEmpty && target?.liveTargetMs == null) return null;
    return toPigeon(
      plan,
      builtAt: now(),
      target: target,
      coachingMuted: coachingMuted,
    );
  }

  /// Whether any run in the last prepare has an event course (K1): the
  /// Home card's event row shows only then (A10.4).
  bool get hasEventCourse => _cached.any((c) {
    final k = c.input.comparisonKey;
    return k != null &&
        engine.ComparisonKey.isParkrun(k) &&
        k != engine.ComparisonKey.parkrun;
  });

  /// The Home ESTIMATED TIMES card (A10.4) from the last prepare, or null
  /// when never prepared. Cheap (no I/O): call [prepare] first.
  engine.HomeEstimates? homeEstimates({bool includeEvent = false}) =>
      _cachedVersion == null
      ? null
      : engine.HomeEstimates.of(
          _cached,
          now: now(),
          names: names,
          includeEvent: includeEvent,
        );

  /// The Start card's target for [spec] (the event or a goal), from the
  /// last prepare; null for other sessions or with nothing to go on.
  engine.StartTarget? targetFor(SessionSpec? spec, {String? courseKey}) =>
      _cachedVersion == null
      ? null
      : engine.StartTarget.forSession(
          spec?.toEngine(),
          runs: _cached,
          now: now(),
          names: names,
          courseKey: courseKey,
        );

  /// The engine's plan as the Pigeon struct `start()` takes.
  static LiveContext toPigeon(
    engine.LivePlan plan, {
    required DateTime builtAt,
    engine.StartTarget? target,
    bool coachingMuted = false,
  }) => LiveContext(
    target: target?.liveTargetMs == null
        ? null
        : LiveTarget(
            distanceM: target!.liveDistanceM!,
            targetMs: target.liveTargetMs!,
            predicted: target.predicted,
          ),
    boards: [
      for (final b in plan.boards)
        LiveBoard(
          key: b.key,
          label: b.label,
          kind: switch (b.kind) {
            engine.LiveBoardPlanKind.distance => LiveBoardKind.distance,
            engine.LiveBoardPlanKind.intervals => LiveBoardKind.intervals,
            engine.LiveBoardPlanKind.cooper => LiveBoardKind.cooper,
            engine.LiveBoardPlanKind.distanceInTime =>
              LiveBoardKind.distanceInTime,
          },
          targetM: b.targetM,
          entries: [
            for (final e in b.entries)
              LiveEntry(
                runId: e.runId,
                dateMs: e.date.millisecondsSinceEpoch,
                fromStartSplitsMs: e.fromStartSplitsMs,
                liveRepPacesSecPerKm: e.liveRepPacesSecPerKm,
                cooperMinuteM: e.cooperMinuteM,
                finalMetric: e.finalMetric,
              ),
          ],
        ),
    ],
    nudges: nudgesToPigeon(plan.nudges),
    cooperCurve: plan.cooperCurve,
    cooperHistory: plan.cooperHistory,
    coachingMuted: coachingMuted,
    builtAtMs: builtAt.millisecondsSinceEpoch,
    engineVersion: engine.engineVersion,
  );

  /// CR1's plan as the Pigeon struct; the LC1 stub (version 0, no rules)
  /// when no rule has enough history.
  static NudgePlan nudgesToPigeon(engine.NudgePlanSpec? n) {
    if (n == null) return NudgePlan(version: 0);
    final fast = n.fastStart;
    final fade = n.repFade;
    final hr = n.hrDrift;
    return NudgePlan(
      version: engine.NudgePlanSpec.version,
      fastStart: fast == null
          ? null
          : FastStartRule(km1MaxMs: fast.km1MaxMs, text: fast.text),
      repFade: fade == null
          ? null
          : RepFadeRule(maxDropSecPerKm: fade.maxDropSecPerKm, text: fade.text),
      hrDrift: hr == null
          ? null
          : HrDriftRule(
              kmSamples: [
                for (final km in hr.kmSamples)
                  [
                    for (final (pace, bpm) in km) [pace, bpm],
                  ],
              ],
              bpmOver: engine.HrDriftRule.bpmOver,
              paceBand: engine.HrDriftRule.paceBand,
              firstKm: engine.HrDriftRule.firstKm,
              minSimilar: engine.HrDriftRule.minSimilar,
              text: hr.text,
            ),
      blocked: n.blocked,
    );
  }
}
