/// Send runs (founder 1-2 Oct): a run leaves the phone only when the runner
/// chooses. Two ways: the Send button on run detail (any target, any time),
/// and services switched on in Settings (all off by default), which get each
/// run automatically after it finishes.
///
/// A target is an [ExportTarget]. Every attempt is logged in the run's
/// sidecar ([engine.SendRecord]), so a run is never sent twice to the same
/// target automatically, and a failed automatic send (offline) is retried on
/// the next app open, up to [engine.SendRecord.maxAutoTries] times.
///
/// Plugging a service in later is one class plus one line in
/// [defaultExportTargets]; the sheet, the Settings section and the retry
/// loop read the list.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../platform/transfer_gateway.dart';
import 'history_store.dart';
import 'settings.dart';

/// File formats "Share file" offers.
enum ExportFormat {
  tcx('tcx', 'application/vnd.garmin.tcx+xml', 'TCX'),
  gpx('gpx', 'application/gpx+xml', 'GPX');

  const ExportFormat(this.extension, this.mimeType, this.label);
  final String extension;
  final String mimeType;
  final String label;
}

/// One run on its way to a target.
@immutable
class SendRequest {
  const SendRequest({
    required this.run,
    required this.title,
    this.format = ExportFormat.tcx,
  });

  final engine.RunFile run;

  /// The title the runner sees for the run (their own name or the automatic
  /// one); names the file.
  final String title;
  final ExportFormat format;
}

@immutable
class SendResult {
  const SendResult.ok() : ok = true, error = null;

  /// [error] is short and fit to show on run detail.
  const SendResult.failed(String this.error) : ok = false;

  final bool ok;
  final String? error;
}

abstract class ExportTarget {
  /// Stable id: the sidecar log key and the Settings key. Never rename.
  String get id;

  /// What the runner sees.
  String get label;

  /// One line under the label in the Send sheet.
  String get blurb;

  /// False for a target that only ever sends when asked (share a file).
  bool get supportsAutomatic => false;

  /// A row shown disabled until its PR lands.
  bool get comingSoon => false;

  /// Switched on for automatic sending in Settings.
  bool isEnabled(AppSettings s) =>
      supportsAutomatic && !comingSoon && s.autoSend.contains(id);

  /// Deliver [req]. Never throws for an expected failure (offline, refused):
  /// return [SendResult.failed] with a short reason.
  Future<SendResult> send(SendRequest req);
}

/// "Run Supreme - Morning Norwegian 4x4 - 2026-10-02.tcx".
String exportFileName(String title, DateTime start, ExportFormat format) {
  final clean = title
      .replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final shown = clean.isEmpty
      ? 'Run'
      : clean.length > 60
      ? clean.substring(0, 60).trim()
      : clean;
  String two(int v) => v.toString().padLeft(2, '0');
  final d = start.toLocal();
  return 'Run Supreme - $shown - ${d.year}-${two(d.month)}-${two(d.day)}'
      '.${format.extension}';
}

/// The file text for [req]: TCX with laps, heart rate, route and
/// timestamps, or GPX with the route, heart rate and one segment per lap.
/// The first and last 200 m of the route are left out (home-trim).
String exportFileText(SendRequest req) => switch (req.format) {
  ExportFormat.tcx => const engine.TcxExporter().export(req.run),
  ExportFormat.gpx => const engine.GpxExporter().export(
    req.run,
    name: req.title,
  ),
};

/// Share a file: opens the phone's share sheet with a TCX or GPX file.
/// Manual only (the runner picks where it goes, so there is nothing to
/// automate).
class ShareFileTarget extends ExportTarget {
  ShareFileTarget({
    required this.transfer,
    Future<Directory> Function()? tempDir,
  }) : _tempDir = tempDir ?? getTemporaryDirectory;

  final TransferGateway transfer;
  final Future<Directory> Function() _tempDir;

  static const String targetId = 'share_file';

  @override
  String get id => targetId;
  @override
  String get label => 'Share file';
  @override
  String get blurb => 'Save it or send it to any app';

  @override
  Future<SendResult> send(SendRequest req) async {
    try {
      final dir = await (await _tempDir()).createTemp('runsupreme-send-');
      final file = File(
        '${dir.path}/${exportFileName(req.title, req.run.start, req.format)}',
      );
      await file.writeAsString(exportFileText(req), flush: true);
      await transfer.shareFiles(
        [file.path],
        subject: 'Run Supreme: ${req.title}',
        mimeType: req.format.mimeType,
      );
      return const SendResult.ok();
    } catch (e) {
      debugPrint('send: share file failed ($e)');
      return const SendResult.failed('Could not open the share sheet');
    }
  }
}

/// Health: a later PR. Platform-neutral: one "health" target backed by one
/// Pigeon `HealthApi` (Health Connect on Android, HealthKit on iOS).
class HealthTarget extends ExportTarget {
  static const String targetId = 'health';

  @override
  String get id => targetId;
  @override
  String get label => Platform.isIOS ? 'Apple Health' : 'Health Connect';
  @override
  String get blurb => 'Coming soon';
  @override
  bool get supportsAutomatic => true;
  @override
  bool get comingSoon => true;

  // TODO(send-runs): `HealthApi.writeWorkout(run file -> session, route, HR,
  // distance, laps)`, implemented natively per platform. Android needs the
  // Play health-apps declaration.
  @override
  Future<SendResult> send(SendRequest req) async =>
      const SendResult.failed('Not available yet');
}

/// Intervals.icu: a later PR.
class IntervalsIcuTarget extends ExportTarget {
  static const String targetId = 'intervals_icu';

  @override
  String get id => targetId;
  @override
  String get label => 'Intervals.icu';
  @override
  String get blurb => 'Coming soon';
  @override
  bool get supportsAutomatic => true;
  @override
  bool get comingSoon => true;

  // TODO(send-runs): POST /api/v1/athlete/0/activities (multipart TCX/GPX,
  // basic auth with the runner's own API key kept in secure storage).
  @override
  Future<SendResult> send(SendRequest req) async =>
      const SendResult.failed('Not available yet');
}

/// Strava has no target: it takes a file the runner uploads themselves.
const String kStravaUploadUrl = 'https://www.strava.com/upload/select';
const String kStravaLine = "Save the file, then upload it on Strava's website";

List<ExportTarget> defaultExportTargets(
  TransferGateway transfer, {
  Future<Directory> Function()? tempDir,
}) => [
  ShareFileTarget(transfer: transfer, tempDir: tempDir),
  HealthTarget(),
  IntervalsIcuTarget(),
];

/// What run detail shows for [record] against [target]; null when the run
/// never went there.
String? sendStateLine(
  ExportTarget target,
  engine.SendRecord? record, {
  required bool autoOn,
}) {
  if (record == null) return null;
  final day = Fmt.dayDate(record.at.toLocal());
  if (record.ok) return target.supportsAutomatic ? 'Sent $day' : 'Shared $day';
  if (!autoOn) return 'Failed';
  return record.tries >= engine.SendRecord.maxAutoTries
      ? 'Failed ${record.tries} times. Tap Send to try again'
      : 'Failed, will retry when you next open the app';
}

/// Sends runs and keeps the log. One per app (see `AppServices`).
class SendCoordinator {
  SendCoordinator({
    required this.history,
    required this.settings,
    required this.targets,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final RunStore history;
  final SettingsController settings;
  final List<ExportTarget> targets;
  final DateTime Function() _now;

  /// Runs looked at by [reconcile]: the newest few cover "retry on next
  /// open" without reading every sidecar.
  static const int retryWindow = 10;

  final Set<String> _inFlight = {};

  ExportTarget? target(String id) {
    for (final t in targets) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// The Send button: [targetId] now, whatever the log says. Logged like any
  /// other attempt.
  Future<SendResult> sendManual(
    String runId,
    String targetId, {
    ExportFormat format = ExportFormat.tcx,
  }) async {
    final t = target(targetId);
    if (t == null) return const SendResult.failed('Unknown target');
    final detail = await history.load(runId);
    if (detail == null) return const SendResult.failed('Run not found');
    return _attempt(t, detail, format);
  }

  /// After a run: every enabled automatic target whose log says a send is
  /// still due. Safe to call twice; a send already running is skipped.
  Future<void> sendAuto(String runId) async {
    final due = [
      for (final t in targets)
        if (t.isEnabled(settings.settings)) t,
    ];
    if (due.isEmpty) return;
    final detail = await history.load(runId);
    if (detail == null) return;
    for (final t in due) {
      if (!detail.sidecar.autoSendDue(t.id)) continue;
      await _attempt(t, detail, ExportFormat.tcx);
    }
  }

  /// On app open: finish what an offline run left behind (failed fewer than
  /// the cap), and send runs finished while the app was closed.
  Future<void> reconcile() async {
    if (!targets.any((t) => t.isEnabled(settings.settings))) return;
    final runs = await history.list();
    for (final r in runs.take(retryWindow)) {
      if (r.missing) continue;
      await sendAuto(r.id);
    }
  }

  Future<SendResult> _attempt(
    ExportTarget t,
    RunDetail detail,
    ExportFormat format,
  ) async {
    final key = '${detail.run.id}|${t.id}';
    if (!_inFlight.add(key)) return const SendResult.failed('Already sending');
    try {
      SendResult result;
      try {
        result = await t.send(
          SendRequest(
            run: detail.run,
            title: runIdentityTitle(detail.summary),
            format: format,
          ),
        );
      } catch (e) {
        debugPrint('send: ${t.id} threw ($e)');
        result = const SendResult.failed('Could not send');
      }
      await history.recordSend(
        detail.run.id,
        t.id,
        ok: result.ok,
        at: _now(),
        error: result.error,
      );
      return result;
    } finally {
      _inFlight.remove(key);
    }
  }
}
