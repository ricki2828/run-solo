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
import '../platform/health_gateway.dart';
import '../platform/platform_api.g.dart';
import '../platform/transfer_gateway.dart';
import 'health_workout.dart';
import 'history_store.dart';
import 'intervals_icu.dart';
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
    this.utcOffsetMin,
  });

  final engine.RunFile run;

  /// The title the runner sees for the run (their own name or the automatic
  /// one); names the file.
  final String title;
  final ExportFormat format;

  /// The phone's UTC offset when the run finished (the sidecar's); null on
  /// older runs, which fall back to the offset now.
  final int? utcOffsetMin;
}

/// Whether a target can take a run right now, and if not why not.
@immutable
class TargetSetup {
  const TargetSetup.ready() : message = null, canInstall = false;
  const TargetSetup.blocked(String this.message, {this.canInstall = false});

  /// Plain words for the runner; null when ready.
  final String? message;

  /// The fix is installing or updating an app: offer its store page.
  final bool canInstall;

  bool get isReady => message == null;
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

  /// Get the target ready (permissions, an installed app) from a runner's tap,
  /// never from the background. Ready by default.
  Future<TargetSetup> prepare() async => const TargetSetup.ready();

  /// Open the store page when [prepare] says [TargetSetup.canInstall].
  Future<void> openInstall() async {}

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
  static const String _dirPrefix = 'runsupreme-send-';

  /// Delete send temp dirs older than [olderThan]. Not deleted right after
  /// the share: on Android the share call returns when the chooser opens,
  /// before the receiving app has read the file. Called on app start and
  /// before each send.
  static Future<void> sweepStale(
    Directory root, {
    Duration olderThan = const Duration(hours: 1),
    DateTime? now,
  }) async {
    final cutoff = (now ?? DateTime.now()).subtract(olderThan);
    try {
      await for (final e in root.list(followLinks: false)) {
        if (e is! Directory ||
            !e.uri.pathSegments
                .where((s) => s.isNotEmpty)
                .last
                .startsWith(_dirPrefix)) {
          continue;
        }
        if ((await e.stat()).modified.isBefore(cutoff)) {
          await e.delete(recursive: true);
        }
      }
    } catch (e) {
      debugPrint('send: temp sweep failed ($e)');
    }
  }

  /// [sweepStale] over this target's temp root.
  Future<void> sweep() async => sweepStale(await _tempDir());

  @override
  String get id => targetId;
  @override
  String get label => 'Share file';
  @override
  String get blurb => 'Save it or send it to any app';

  @override
  Future<SendResult> send(SendRequest req) async {
    try {
      final root = await _tempDir();
      await sweepStale(root);
      final dir = await root.createTemp(_dirPrefix);
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

/// Health: one platform-neutral target over one [HealthGateway] (Health
/// Connect on Android; HealthKit on iOS is a later PR). Writes the run as an
/// exercise session with laps, pauses, heart rate, distance and route.
/// Writing the same run again replaces it (the run id is the record id).
class HealthTarget extends ExportTarget {
  HealthTarget({required this.gateway, DateTime Function()? now, bool? ios})
    : _now = now ?? DateTime.now,
      _ios = ios ?? Platform.isIOS;

  final HealthGateway gateway;
  final DateTime Function() _now;
  final bool _ios;

  static const String targetId = 'health';

  @override
  String get id => targetId;
  @override
  String get label => _ios ? 'Apple Health' : 'Health Connect';
  @override
  String get blurb => 'Run, heart rate, distance and route';
  @override
  bool get supportsAutomatic => true;

  // HealthKit lands in its own PR.
  @override
  bool get comingSoon => _ios;

  static TargetSetup? _problemOf(HealthAvailability a) => switch (a) {
    HealthAvailability.available => null,
    HealthAvailability.notInstalled => const TargetSetup.blocked(
      'Health Connect is not installed.',
      canInstall: true,
    ),
    HealthAvailability.needsUpdate => const TargetSetup.blocked(
      'Health Connect needs an update.',
      canInstall: true,
    ),
    HealthAvailability.unsupported => const TargetSetup.blocked(
      'Health Connect is not available on this phone.',
    ),
  };

  @override
  Future<TargetSetup> prepare() async {
    var s = await gateway.status();
    final problem = _problemOf(s.availability);
    if (problem != null) return problem;
    if (!s.coreGranted) {
      if (!await gateway.requestAccess(route: false)) {
        return const TargetSetup.blocked(
          'Allow Run Supreme to write exercise, heart rate and distance in '
          'Health Connect.',
        );
      }
    }
    // The route is its own permission. Without it runs still go, minus the
    // map, so a refusal is not a blocker.
    if (!s.routeGranted) await gateway.requestAccess(route: true);
    return const TargetSetup.ready();
  }

  @override
  Future<void> openInstall() => gateway.openInstall();

  @override
  Future<SendResult> send(SendRequest req) async {
    final s = await gateway.status();
    final problem = _problemOf(s.availability);
    if (problem != null) return SendResult.failed(problem.message!);
    if (!s.coreGranted) {
      return const SendResult.failed('Health Connect access is off');
    }
    final now = _now();
    final workout = HealthWorkoutBuilder.build(
      req.run,
      title: req.title,
      utcOffsetSeconds: (req.utcOffsetMin ?? now.timeZoneOffset.inMinutes) * 60,
      version: now.millisecondsSinceEpoch,
    );
    final r = await gateway.writeWorkout(workout);
    return switch (r.outcome) {
      HealthWriteOutcome.written ||
      HealthWriteOutcome.writtenWithoutRoute => const SendResult.ok(),
      HealthWriteOutcome.notAvailable => const SendResult.failed(
        'Health Connect is not available',
      ),
      HealthWriteOutcome.permissionDenied => const SendResult.failed(
        'Health Connect access is off',
      ),
      HealthWriteOutcome.failed => SendResult.failed(
        r.detail ?? 'Could not write to Health Connect',
      ),
    };
  }
}

/// Strava has no target: it takes a file the runner uploads themselves.
const String kStravaUploadUrl = 'https://www.strava.com/upload/select';
const String kStravaLine = "Save the file, then upload it on Strava's website";

List<ExportTarget> defaultExportTargets(
  TransferGateway transfer,
  HealthGateway health, {
  Future<Directory> Function()? tempDir,
  DateTime Function()? now,
  SecretStore? secrets,
  IntervalsHttp? intervalsHttp,
}) => [
  ShareFileTarget(transfer: transfer, tempDir: tempDir),
  HealthTarget(gateway: health, now: now),
  IntervalsIcuTarget(
    store: secrets ?? SecureSecretStore(),
    http: intervalsHttp,
  ),
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

/// How a [SendCoordinator.sendAllPast] pass ended.
@immutable
class BackfillResult {
  const BackfillResult({
    required this.total,
    required this.sent,
    this.firstError,
  });

  /// Runs attempted (runs whose file is missing are not counted).
  final int total;
  final int sent;

  /// The first failure's short reason, null when every run went.
  final String? firstError;

  int get failed => total - sent;
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
    return _attempt(t, detail, format, auto: false);
  }

  /// Settings "Send all past runs": every run on the phone, oldest first, to
  /// [targetId], whatever the log says. Safe to run twice: a health write
  /// replaces the record with the same run id. Logged like any other manual
  /// send. [onProgress] gets (done, total) before the first run and after
  /// each one.
  Future<BackfillResult> sendAllPast(
    String targetId, {
    void Function(int done, int total)? onProgress,
  }) async {
    final t = target(targetId);
    if (t == null) {
      return const BackfillResult(
        total: 0,
        sent: 0,
        firstError: 'Unknown target',
      );
    }
    final runs = [
      for (final r in await history.list())
        if (!r.missing) r,
    ]..sort((a, b) => a.start.compareTo(b.start));
    onProgress?.call(0, runs.length);
    var sent = 0;
    String? firstError;
    for (var i = 0; i < runs.length; i++) {
      final detail = await history.load(runs[i].id);
      final result = detail == null
          ? const SendResult.failed('Run not found')
          : await _attempt(t, detail, ExportFormat.tcx, auto: false);
      if (result.ok) {
        sent += 1;
      } else {
        firstError ??= result.error;
      }
      onProgress?.call(i + 1, runs.length);
    }
    return BackfillResult(
      total: runs.length,
      sent: sent,
      firstError: firstError,
    );
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
    final since = settings.settings.autoSendSince;
    for (final t in due) {
      if (!detail.sidecar.autoSendDue(t.id)) continue;
      // Only runs that finished after the target was switched on; older
      // ones go through the Send button.
      final on = since[t.id];
      if (on == null || !detail.run.end.isAfter(on)) continue;
      await _attempt(t, detail, ExportFormat.tcx, auto: true);
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
    ExportFormat format, {
    required bool auto,
  }) async {
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
            utcOffsetMin: detail.sidecar.utcOffsetMin,
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
        auto: auto,
      );
      return result;
    } finally {
      _inFlight.remove(key);
    }
  }
}
