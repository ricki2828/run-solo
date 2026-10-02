import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/run_index.dart';

import '../run_fixtures.dart';

/// A run's time of day is the wall clock where it started: worked out from
/// the start fix (DST-correct at that instant), backfilled onto older runs,
/// and never read in the phone's current zone when the run has a fix.
void main() {
  const singapore = (lat: 1.3521, lon: 103.8198);
  const athens = (lat: 37.9838, lon: 23.7275);

  /// [r] started somewhere else: every fix moved to [at], its zone label
  /// and app as given. Nothing else changes.
  engine.RunFile relocated(
    engine.RunFile r,
    ({double lat, double lon})? at, {
    String tz = 'UTC',
    String app = 'test',
  }) => engine.RunFile(
    id: r.id,
    device: r.device,
    app: app,
    start: r.start,
    end: r.end,
    tz: tz,
    mode: r.mode,
    session: r.session,
    units: r.units,
    laps: r.laps,
    pauses: r.pauses,
    gaps: r.gaps,
    samples: [
      for (final s in r.samples)
        engine.Sample(
          tMs: s.tMs,
          lat: at == null || !s.hasFix ? null : at.lat,
          lon: at == null || !s.hasFix ? null : at.lon,
          altM: s.altM,
          accM: s.accM,
          speedMps: s.speedMps,
          distM: s.distM,
          hr: s.hr,
        ),
    ],
    nudgesFired: r.nudgesFired,
  );

  late Directory dir;
  late FileRunStore store;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('runsolo-localtime-');
    store = FileRunStore(Directory('${dir.path}/runs'));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<RunSummary> only() async => (await store.list()).single;

  test(
    'Singapore 15:00 reads Afternoon 15:00 with the phone anywhere',
    () async {
      // 07:00 UTC. The phone (this test host, so also "Athens") stamped +3.
      final r = relocated(
        freeRunFile(n: 1, start: DateTime.utc(2026, 10, 2, 7)),
        singapore,
      );
      await store.importBundles([
        engine.RunBundle(
          run: r,
          sidecar: engine.RunSidecar(runId: r.id).copyWith(utcOffsetMin: 180),
        ),
      ]);
      final s = await only();
      expect(s.utcOffsetMin, 480);
      expect(s.localStart.hour, 15);
      expect(runIdentityTitle(s), startsWith('Afternoon'));
      expect(runWhereWhen(s), endsWith('Fri 2 Oct · 15:00'));
    },
  );

  test('Athens across the late-October clock change', () async {
    final a = relocated(
      freeRunFile(n: 1, start: DateTime.utc(2026, 10, 24, 14)),
      athens,
    );
    final b = relocated(
      freeRunFile(n: 2, start: DateTime.utc(2026, 10, 26, 14)),
      athens,
    );
    await store.importBundles([
      engine.RunBundle(run: a),
      engine.RunBundle(run: b),
    ]);
    final byId = {for (final s in await store.list()) s.id: s};
    expect(byId[a.id]!.utcOffsetMin, 180);
    expect(byId[a.id]!.localStart.hour, 17);
    expect(runIdentityTitle(byId[a.id]!), startsWith('Evening'));
    expect(byId[b.id]!.utcOffsetMin, 120);
    expect(byId[b.id]!.localStart.hour, 16);
    expect(runIdentityTitle(byId[b.id]!), startsWith('Afternoon'));
  });

  test('an indoor run uses the offset stamped at finish', () async {
    final r = relocated(
      freeRunFile(n: 1, start: DateTime.utc(2026, 10, 2, 7)),
      null,
    );
    await store.importBundles([engine.RunBundle(run: r)]);
    expect((await only()).utcOffsetMin, isNull, reason: 'nothing known yet');
    await store.setUtcOffset(r.id, 480);
    await store.stampLocalTime(r.id);
    final s = await only();
    expect(s.utcOffsetMin, 480);
    expect(s.localStart.hour, 15);
    expect((await store.load(r.id))!.sidecar.zoneId, isNull);
  });

  test('old runs with no offset are backfilled and persisted', () async {
    final r = relocated(
      freeRunFile(n: 1, start: DateTime.utc(2026, 9, 24, 6)),
      singapore,
    );
    await store.importBundles([engine.RunBundle(run: r)]);
    final sidecarFile = File('${store.runsDir.path}/run-${r.id}.edits.json');
    expect(sidecarFile.existsSync(), isFalse, reason: 'as before #138');
    final s = await only();
    expect(s.utcOffsetMin, 480);
    expect(runIdentityTitle(s), startsWith('Afternoon'));
    // The zone and offset are now in the sidecar and in the index row.
    final sc = (await store.load(r.id))!.sidecar;
    expect((sc.zoneId, sc.utcOffsetMin), ('Asia/Singapore', 480));
    final row = (await store.readIndex()).entries[r.id]!.row!;
    expect((row.zoneId, row.utcOffsetMin), ('Asia/Singapore', 480));
    expect(row.version, IndexRow.currentVersion);
    await store.derivedIdle;
  });

  test('a row from before the zone was kept is rebuilt with it', () async {
    final r = relocated(
      freeRunFile(n: 1, start: DateTime.utc(2026, 9, 24, 6)),
      singapore,
    );
    await store.importBundles([engine.RunBundle(run: r)]);
    await store.list();
    await store.derivedIdle;
    final text = store.indexFile.readAsStringSync();
    store.indexFile.writeAsStringSync(
      text
          .replaceAll('"v":${IndexRow.currentVersion}', '"v":7')
          .replaceAll(RegExp(r',?"zone_id":"[^"]*"'), '')
          .replaceAll(RegExp(r'"utc_offset_min":\d+'), '"utc_offset_min":180'),
    );
    final s = await only();
    expect(s.utcOffsetMin, 480, reason: 'the stale 180 is not trusted');
    final row = (await store.readIndex()).entries[r.id]!.row!;
    expect(row.zoneId, 'Asia/Singapore');
    await store.derivedIdle;
  });

  test('an imported GPX run is placed by its fix, not read as UTC', () async {
    const gpx = '''<?xml version="1.0"?>
<gpx version="1.1" creator="watch"><trk><trkseg>
<trkpt lat="1.3521" lon="103.8198"><time>2026-09-24T07:00:00Z</time></trkpt>
<trkpt lat="1.3530" lon="103.8198"><time>2026-09-24T07:30:00Z</time></trkpt>
</trkseg></trk></gpx>''';
    final r = const engine.GpxImporter().import(gpx);
    await store.importBundles([engine.RunBundle(run: r)]);
    final s = await only();
    expect(s.utcOffsetMin, 480);
    expect(runIdentityTitle(s), startsWith('Afternoon'));
  });

  test('the in-memory store resolves the same way', () async {
    final r = relocated(
      freeRunFile(n: 1, start: DateTime.utc(2026, 10, 2, 7)),
      singapore,
    );
    final mem = MemoryRunStore(files: [r]);
    final s = (await mem.list()).single;
    expect(s.utcOffsetMin, 480);
    expect(s.localStart.hour, 15);
  });
}
