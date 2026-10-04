/// Send to watch (founder 4 Oct): a session as a FIT workout, a route as a
/// GPX course, handed to the system share sheet. Nothing leaves the phone
/// until the runner picks an app. Files go in the same `runsupreme-send-`
/// temp folders the Send runs target uses, so its sweep cleans them up.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../platform/transfer_gateway.dart';
import 'send_runs.dart' show ShareFileTarget;

class WatchExporter {
  WatchExporter({
    required this.transfer,
    Future<Directory> Function()? tempDir,
    DateTime Function()? now,
  }) : _tempDir = tempDir ?? getTemporaryDirectory,
       _now = now ?? DateTime.now;

  final TransferGateway transfer;
  final Future<Directory> Function() _tempDir;
  final DateTime Function() _now;

  static const String fitMime = 'application/octet-stream';
  static const String gpxMime = 'application/gpx+xml';

  /// A safe file name: letters, digits, spaces and dashes only.
  static String fileName(String title, String extension) {
    final clean = title
        .replaceAll(RegExp(r'[^A-Za-z0-9 \-]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final shown = clean.isEmpty
        ? 'Session'
        : (clean.length > 40 ? clean.substring(0, 40).trim() : clean);
    return 'Run Supreme - $shown.$extension';
  }

  /// Share [workout] as a `.fit`. Null when it went to the share sheet, else
  /// a plain reason.
  Future<String?> shareWorkout(engine.FitWorkout workout) async {
    try {
      final bytes = engine.FitWorkoutEncoder.encode(workout, created: _now());
      final file = await _file(fileName(workout.name, 'fit'));
      await file.writeAsBytes(bytes, flush: true);
      await transfer.shareFiles(
        [file.path],
        subject: 'Run Supreme: ${workout.name}',
        mimeType: fitMime,
      );
      return null;
    } catch (e) {
      debugPrint('watch: workout share failed ($e)');
      return 'Could not open the share sheet';
    }
  }

  /// Share [route] as a GPX course. Same return as [shareWorkout].
  Future<String?> shareRoute(engine.SavedRoute route) async {
    try {
      final text = const engine.GpxCourseExporter().export(route);
      final file = await _file(fileName(route.name, 'gpx'));
      await file.writeAsString(text, flush: true);
      await transfer.shareFiles(
        [file.path],
        subject: 'Run Supreme: ${route.name}',
        mimeType: gpxMime,
      );
      return null;
    } catch (e) {
      debugPrint('watch: route share failed ($e)');
      return 'Could not open the share sheet';
    }
  }

  Future<File> _file(String name) async {
    final root = await _tempDir();
    await ShareFileTarget.sweepStale(root);
    final dir = await root.createTemp('runsupreme-send-');
    return File('${dir.path}/$name');
  }
}
