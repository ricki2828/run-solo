/// The live "you vs you" context for a Start (Phase 4 plan §3.2, LC1).
///
/// Built from `index.json` (W5b) and each entry's derived data (LB2), never
/// from run files, inside a hard 150 ms budget (WARN-3). On timeout, a
/// missing index, an empty plan or any error the answer is null: Start goes
/// ahead with no compare, no overlay and nothing said. The fold is cached
/// per index version (file size + mtime), so the Start after a History open
/// costs a lookup.
///
/// Off by default ([kLiveCompare]): comparisons fire only once the in-app
/// mute (LV2) ships in the same build, because Laps and Intervals runs have
/// no room for a "Mute tips" notification action (#48 review).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/event_names.dart';
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

  final File indexFile;
  final Duration budget;
  final engine.EventNames names;
  final DateTime Function() now;

  String? _cachedVersion;
  List<engine.LiveCandidate> _cached = const [];

  /// Test seam: runs inside the budget before the fold (a slow index).
  @visibleForTesting
  Future<void> Function()? beforeFold;

  /// The context for a Start of [mode] with [spec] (and [courseKey] for the
  /// Saturday 5 km when the app knows it), or null. Never throws, never
  /// waits longer than [budget].
  Future<LiveContext?> build({
    required RecordMode mode,
    SessionSpec? spec,
    String? courseKey,
  }) async {
    try {
      return await _build(mode, spec, courseKey).timeout(budget);
    } on TimeoutException {
      debugPrint('live: context over ${budget.inMilliseconds} ms, none');
      return null;
    } catch (e) {
      debugPrint('live: no context ($e)');
      return null;
    }
  }

  Future<LiveContext?> _build(
    RecordMode mode,
    SessionSpec? spec,
    String? courseKey,
  ) async {
    final stat = await indexFile.stat();
    if (stat.type == FileSystemEntityType.notFound) return null;
    final version = '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
    if (version != _cachedVersion) {
      final index = await RunIndex.read(indexFile);
      _cached = [for (final e in index.entries.values) ?e.liveCandidate()];
      _cachedVersion = version;
    }
    await beforeFold?.call();
    final plan = engine.LivePlanner.plan(
      mode: runModeOf(mode),
      session: spec?.toEngine(),
      courseKey: courseKey,
      runs: _cached,
      names: names,
    );
    if (plan.isEmpty) return null;
    return toPigeon(plan, builtAt: now());
  }

  /// The engine's plan as the Pigeon struct `start()` takes.
  static LiveContext toPigeon(
    engine.LivePlan plan, {
    required DateTime builtAt,
  }) => LiveContext(
    boards: [
      for (final b in plan.boards)
        LiveBoard(
          key: b.key,
          label: b.label,
          kind: switch (b.kind) {
            engine.LiveBoardPlanKind.distance => LiveBoardKind.distance,
            engine.LiveBoardPlanKind.intervals => LiveBoardKind.intervals,
            engine.LiveBoardPlanKind.cooper => LiveBoardKind.cooper,
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
    // LC1 ships the stub; CR1 fills the rules.
    nudges: NudgePlan(version: 0),
    cooperCurve: plan.cooperCurve,
    cooperHistory: plan.cooperHistory,
    coachingMuted: false,
    builtAtMs: builtAt.millisecondsSinceEpoch,
    engineVersion: engine.engineVersion,
  );
}
