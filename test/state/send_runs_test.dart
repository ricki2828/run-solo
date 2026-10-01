import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/transfer_gateway.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/send_runs.dart';
import 'package:run_solo/state/settings.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// An automatic target that records every send and can be told to fail.
class _AutoTarget extends ExportTarget {
  _AutoTarget(this.id);
  @override
  final String id;
  @override
  String get label => id;
  @override
  String get blurb => '';
  @override
  bool get supportsAutomatic => true;

  int sends = 0;
  bool offline = false;

  @override
  Future<SendResult> send(SendRequest req) async {
    sends += 1;
    return offline
        ? const SendResult.failed('No network')
        : const SendResult.ok();
  }
}

void main() {
  final start = DateTime.utc(2026, 10, 2, 6);
  late engine.RunFile run;
  late MemoryRunStore store;
  late SettingsController settings;
  late _AutoTarget auto;
  late SendCoordinator coordinator;

  SendCoordinator build({Set<String> on = const {'auto'}}) {
    run = fourByFourFile(n: 1, start: start);
    store = MemoryRunStore(files: [run], now: now);
    auto = _AutoTarget('auto');
    final initial = AppSettings(autoSend: on);
    settings = SettingsController(MemorySettingsStore(initial), initial);
    return coordinator = SendCoordinator(
      history: store,
      settings: settings,
      targets: [auto, _AutoTarget('other')],
      now: now,
    );
  }

  group('file names', () {
    test('Run Supreme - <title> - <date>.<ext>', () {
      expect(
        exportFileName(
          'Morning Norwegian 4x4',
          DateTime(2026, 10, 2, 6),
          ExportFormat.tcx,
        ),
        'Run Supreme - Morning Norwegian 4x4 - 2026-10-02.tcx',
      );
    });

    test('path characters and blank titles are cleaned', () {
      final name = exportFileName(
        'a/b:c  "d"?',
        DateTime(2026, 1, 5),
        ExportFormat.gpx,
      );
      expect(name, 'Run Supreme - a b c d - 2026-01-05.gpx');
      expect(
        exportFileName('  ', DateTime(2026, 1, 5), ExportFormat.gpx),
        'Run Supreme - Run - 2026-01-05.gpx',
      );
    });
  });

  group('share a file', () {
    test('writes the TCX and GPX under the right name and mime type', () async {
      final r = fourByFourFile(n: 2, start: start);
      final transfer = FakeTransferGateway();
      final target = ShareFileTarget(
        transfer: transfer,
        tempDir: () async => Directory.systemTemp,
      );
      final texts = <String>[];
      for (final f in ExportFormat.values) {
        final next = transfer.nextShare();
        final result = await target.send(
          SendRequest(run: r, title: 'Test run', format: f),
        );
        expect(result.ok, isTrue);
        final path = (await next).single;
        expect(path.split('/').last, startsWith('Run Supreme - Test run - '));
        expect(path, endsWith('.${f.extension}'));
        texts.add(File(path).readAsStringSync());
      }
      expect(transfer.sharedMimeTypes, [
        'application/vnd.garmin.tcx+xml',
        'application/gpx+xml',
      ]);
      expect(texts[0], contains('<Lap '));
      expect(texts[0], contains('<HeartRateBpm>'));
      expect(texts[1], contains('<trkseg>'));
    });

    test(
      'a share sheet that cannot open is a failed result, not a throw',
      () async {
        final transfer = FakeTransferGateway()..failShare = true;
        final result =
            await ShareFileTarget(
              transfer: transfer,
              tempDir: () async => Directory.systemTemp,
            ).send(
              SendRequest(
                run: fourByFourFile(n: 3, start: start),
                title: 'x',
              ),
            );
        expect(result.ok, isFalse);
        expect(result.error, isNotNull);
      },
    );
  });

  group('send log', () {
    test(
      'a run is never sent twice to the same target automatically',
      () async {
        build();
        await coordinator.sendAuto(run.id);
        await coordinator.sendAuto(run.id);
        await coordinator.reconcile();
        expect(auto.sends, 1);
        expect(store.sidecars[run.id]!.sends['auto']!.ok, isTrue);
      },
    );

    test('only targets switched on in Settings are sent to', () async {
      build(on: const {});
      await coordinator.sendAuto(run.id);
      expect(auto.sends, 0);
      expect(store.sidecars[run.id]?.sends ?? const {}, isEmpty);
    });

    test('offline: retried on each open, stops after three failures', () async {
      build();
      auto.offline = true;
      await coordinator.sendAuto(run.id);
      expect(auto.sends, 1);
      for (var open = 0; open < 5; open++) {
        await coordinator.reconcile();
      }
      expect(auto.sends, engine.SendRecord.maxAutoTries);
      final rec = store.sidecars[run.id]!.sends['auto']!;
      expect(rec.ok, isFalse);
      expect(rec.tries, engine.SendRecord.maxAutoTries);
      expect(rec.error, 'No network');
    });

    test('back online: the next open sends once and then stops', () async {
      build();
      auto.offline = true;
      await coordinator.sendAuto(run.id);
      auto.offline = false;
      await coordinator.reconcile();
      await coordinator.reconcile();
      expect(auto.sends, 2);
      expect(store.sidecars[run.id]!.sends['auto']!.ok, isTrue);
      expect(store.sidecars[run.id]!.sends['auto']!.tries, 0);
    });

    test('the Send button sends again whatever the log says', () async {
      build();
      await coordinator.sendAuto(run.id);
      final r = await coordinator.sendManual(run.id, 'auto');
      expect(r.ok, isTrue);
      expect(auto.sends, 2);
    });

    test('a target that throws is logged as a failure', () async {
      build();
      final t = _ThrowingTarget();
      final c = SendCoordinator(
        history: store,
        settings: SettingsController(
          MemorySettingsStore(const AppSettings(autoSend: {'boom'})),
          const AppSettings(autoSend: {'boom'}),
        ),
        targets: [t],
        now: now,
      );
      await c.sendAuto(run.id);
      expect(store.sidecars[run.id]!.sends['boom']!.ok, isFalse);
    });

    test('state line: sent, retry waiting, gave up', () {
      final t = _AutoTarget('auto');
      final at = DateTime.utc(2026, 10, 2);
      expect(sendStateLine(t, null, autoOn: true), isNull);
      expect(
        sendStateLine(t, engine.SendRecord(ok: true, at: at), autoOn: true),
        'Sent Fri 2 Oct',
      );
      expect(
        sendStateLine(
          t,
          engine.SendRecord(ok: false, at: at, tries: 1),
          autoOn: true,
        ),
        contains('retry'),
      );
      expect(
        sendStateLine(
          t,
          engine.SendRecord(ok: false, at: at, tries: 3),
          autoOn: true,
        ),
        contains('try again'),
      );
    });
  });

  test('FileRunStore: the log survives a restart and the cap holds', () async {
    final dir = Directory.systemTemp.createTempSync('runsolo-send-');
    final store = FileRunStore(Directory('${dir.path}/runs'));
    addTearDown(() async {
      await store.derivedIdle;
      dir.deleteSync(recursive: true);
    });
    final r = freeRunFile(n: 1, start: start);
    await store.importBundles([engine.RunBundle(run: r)]);
    final t = _AutoTarget('auto')..offline = true;
    const on = AppSettings(autoSend: {'auto'});
    SendCoordinator open() => SendCoordinator(
      history: FileRunStore(Directory('${dir.path}/runs')),
      settings: SettingsController(MemorySettingsStore(on), on),
      targets: [t],
      now: now,
    );
    // Each "open" is a fresh coordinator over the same files.
    for (var i = 0; i < 5; i++) {
      await open().sendAuto(r.id);
    }
    expect(t.sends, engine.SendRecord.maxAutoTries);
    final saved = (await store.load(r.id))!.sidecar.sends['auto']!;
    expect(saved.tries, engine.SendRecord.maxAutoTries);
    t.offline = false;
    await open().sendManual(r.id, 'auto');
    expect((await store.load(r.id))!.sidecar.sends['auto']!.ok, isTrue);
    await open().sendAuto(r.id);
    expect(t.sends, engine.SendRecord.maxAutoTries + 1);
  });

  test('autoSend settings round-trip and default to off', () {
    expect(const AppSettings().autoSend, isEmpty);
    expect(const AppSettings().toJson().containsKey('autoSend'), isFalse);
    final back = AppSettings.fromJson(
      const AppSettings(autoSend: {'a', 'b'}).toJson(),
    );
    expect(back.autoSend, {'a', 'b'});
    expect(AppSettings.fromJson({'autoSend': 'junk'}).autoSend, isEmpty);
  });
}

class _ThrowingTarget extends ExportTarget {
  @override
  String get id => 'boom';
  @override
  String get label => 'Boom';
  @override
  String get blurb => '';
  @override
  bool get supportsAutomatic => true;
  @override
  Future<SendResult> send(SendRequest req) => throw StateError('boom');
}
