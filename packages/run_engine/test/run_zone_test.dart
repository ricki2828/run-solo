import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

const _singapore = (lat: 1.3521, lon: 103.8198);
const _athens = (lat: 37.9838, lon: 23.7275);

RunFile _run(
  DateTime start, {
  ({double lat, double lon})? at,
  String tz = 'UTC',
  String app = 'test',
}) => RunFile(
  id: '00000000-0000-4000-8000-0000000000aa',
  device: 'test',
  app: app,
  start: start,
  end: start.add(const Duration(minutes: 30)),
  tz: tz,
  mode: RunMode.free,
  units: Units.km,
  laps: const [],
  samples: [
    Sample(tMs: 0, lat: at?.lat, lon: at?.lon, distM: 0),
    Sample(tMs: 1000, lat: at?.lat, lon: at?.lon, distM: 3),
  ],
);

String _title(RunFile run, RunLocalZone? z) =>
    RunIdentity.timeOfDay(RunIdentity.localStart(run.start, z?.offsetMin));

void main() {
  group('cause: a missing offset is judged in the phone zone', () {
    // A Singapore afternoon is 06:00-08:59 UTC. With no offset the old code
    // used the phone's CURRENT zone, so a run read after travelling moves.
    final start = DateTime.utc(2026, 9, 24, 7); // 15:00 Singapore

    test('null offset follows the phone zone, not the run', () {
      expect(RunIdentity.localStart(start, null), start.toLocal());
    });

    test('offset 0 or the wrong zone gives Early/Morning for 15:00 SGT', () {
      expect(
        RunIdentity.timeOfDay(RunIdentity.localStart(start, 0)),
        'Morning',
      );
      final early = DateTime.utc(2026, 9, 24, 6); // 14:00 Singapore
      expect(RunIdentity.timeOfDay(RunIdentity.localStart(early, 0)), 'Early');
      expect(
        RunIdentity.timeOfDay(RunIdentity.localStart(early, 480)),
        'Afternoon',
      );
    });
  });

  group('zone lookup', () {
    test('finds the IANA zone from a fix', () {
      expect(RunZone.zoneAt(_singapore.lat, _singapore.lon), 'Asia/Singapore');
      expect(RunZone.zoneAt(_athens.lat, _athens.lon), 'Europe/Athens');
      expect(RunZone.zoneAt(41.9, 12.5), 'Europe/Rome');
    });

    test('cities across the world, coast and inland', () {
      const cities = {
        'Australia/Sydney': (-33.8568, 151.2153), // Opera House, on the water
        'Australia/Perth': (-31.95, 115.86),
        'Pacific/Auckland': (-36.85, 174.76),
        'Asia/Kolkata': (28.61, 77.21),
        'Asia/Kathmandu': (27.7, 85.32),
        'Europe/London': (51.5, -0.12),
        'Europe/Lisbon': (38.72, -9.14),
        'Europe/Madrid': (40.42, -3.7),
        'Europe/Istanbul': (41.01, 28.97),
        'Africa/Johannesburg': (-26.2, 28.04),
        'Africa/Cairo': (30.04, 31.24),
        'America/New_York': (40.71, -74.0),
        'America/Los_Angeles': (34.05, -118.24),
        'America/Sao_Paulo': (-23.55, -46.63),
        'America/St_Johns': (47.56, -52.71),
        'Asia/Tokyo': (35.68, 139.69),
        'Asia/Shanghai': (31.23, 121.47),
        'Europe/Athens': (37.97, 23.72),
        'Europe/Rome': (41.9, 12.5),
      };
      for (final MapEntry(key: id, value: (lat, lon)) in cities.entries) {
        final got = RunZone.zoneAt(lat, lon)!;
        final at = DateTime.utc(2026, 10, 2, 7);
        expect(
          RunZone.offsetAt(got, at),
          RunZone.offsetAt(id, at),
          reason: '$id: grid said $got',
        );
      }
    });

    test('no zone in the open sea', () {
      expect(RunZone.zoneAt(0, -30), isNull);
    });

    test('unknown ids give no offset', () {
      expect(RunZone.offsetAt('Not/AZone', DateTime.utc(2026)), isNull);
    });
  });

  group('resolve', () {
    test('Singapore 15:00 is Afternoon 15:00, whatever the phone zone', () {
      final run = _run(DateTime.utc(2026, 10, 2, 7), at: _singapore);
      final z = RunZone.resolve(run)!;
      expect(z.zoneId, 'Asia/Singapore');
      expect(z.offsetMin, 480);
      final local = RunIdentity.localStart(run.start, z.offsetMin);
      expect((local.hour, local.minute), (15, 0));
      expect(RunIdentity.timeOfDay(local), 'Afternoon');
    });

    test(
      'the fix beats a stamped offset from the phone (Athens at finish)',
      () {
        final run = _run(DateTime.utc(2026, 10, 2, 7), at: _singapore);
        final z = RunZone.resolve(run, stampedOffsetMin: 180)!;
        expect(z.offsetMin, 480);
      },
    );

    test('Athens across the late-October clock change', () {
      // EEST (+3) until 04:00 local on Sun 25 Oct 2026 (01:00 UTC), then +2.
      final before = _run(DateTime.utc(2026, 10, 24, 14), at: _athens);
      final after = _run(DateTime.utc(2026, 10, 26, 14), at: _athens);
      final zb = RunZone.resolve(before)!;
      final za = RunZone.resolve(after)!;
      expect((zb.offsetMin, za.offsetMin), (180, 120));
      expect(RunIdentity.localStart(before.start, zb.offsetMin).hour, 17);
      expect(_title(before, zb), 'Evening');
      expect(RunIdentity.localStart(after.start, za.offsetMin).hour, 16);
      expect(_title(after, za), 'Afternoon');
    });

    test('a stored zone id gives the offset at the start instant', () {
      final summer = _run(DateTime.utc(2026, 7, 1, 12));
      final winter = _run(DateTime.utc(2026, 12, 1, 12));
      expect(RunZone.resolve(summer, zoneId: 'Europe/Athens')!.offsetMin, 180);
      expect(RunZone.resolve(winter, zoneId: 'Europe/Athens')!.offsetMin, 120);
    });

    test('indoor run uses the stamped offset', () {
      final run = _run(DateTime.utc(2026, 10, 2, 7));
      final z = RunZone.resolve(run, stampedOffsetMin: 480)!;
      expect(z.zoneId, isNull);
      expect(z.offsetMin, 480);
    });

    test('indoor run on a native file prefers its own tz over the stamp', () {
      final run = _run(DateTime.utc(2026, 10, 2, 7), tz: 'Asia/Singapore');
      final z = RunZone.resolve(run, stampedOffsetMin: 180)!;
      expect((z.zoneId, z.offsetMin), ('Asia/Singapore', 480));
    });

    test('an import tz placeholder is ignored', () {
      final run = _run(DateTime.utc(2026, 10, 2, 7), app: 'import:gpx');
      expect(RunZone.resolve(run), isNull);
      expect(RunZone.resolve(run, stampedOffsetMin: 480)!.offsetMin, 480);
    });

    test('nothing known: null, so the caller falls back to the phone', () {
      final imported = _run(DateTime.utc(2026, 10, 2, 7), app: 'import:tcx');
      expect(RunZone.resolve(imported), isNull);
    });

    test('an older run (null offset) backfills from its start fix', () {
      final run = _run(DateTime.utc(2026, 9, 24, 6), at: _singapore);
      // No sidecar offset or zone at all, as every run before #138.
      final z = RunZone.resolve(run, zoneId: null, stampedOffsetMin: null)!;
      expect((z.zoneId, z.offsetMin), ('Asia/Singapore', 480));
      expect(_title(run, z), 'Afternoon');
    });
  });

  group('imports', () {
    const gpx = '''<?xml version="1.0"?>
<gpx version="1.1" creator="watch"><trk><trkseg>
<trkpt lat="1.3521" lon="103.8198"><time>2026-09-24T07:00:00Z</time></trkpt>
<trkpt lat="1.3530" lon="103.8198"><time>2026-09-24T07:05:00Z</time></trkpt>
</trkseg></trk></gpx>''';

    test('a GPX run is placed by its fix, not by the UTC placeholder', () {
      final run = const GpxImporter().import(gpx);
      expect(run.tz, 'UTC');
      final z = RunZone.resolve(run)!;
      expect((z.zoneId, z.offsetMin), ('Asia/Singapore', 480));
      expect(_title(run, z), 'Afternoon');
    });

    test('a GPX run with no fix and no offset stays unresolved', () {
      final noFix = gpx
          .replaceAll(' lat="1.3521" lon="103.8198"', ' lat="0" lon="0"')
          .replaceAll(' lat="1.3530" lon="103.8198"', ' lat="0" lon="0"');
      final run = const GpxImporter().import(noFix);
      // (0,0) is open sea: no zone, and an import tz is not evidence.
      expect(RunZone.resolve(run), isNull);
    });

    test('a TCX with a Z time resolves by its fix as well', () {
      const tcx = '''<?xml version="1.0"?>
<TrainingCenterDatabase><Activities><Activity Sport="Running"><Id>x</Id>
<Lap StartTime="2026-09-24T07:00:00Z"><TotalTimeSeconds>300</TotalTimeSeconds><DistanceMeters>1000</DistanceMeters><Track>
<Trackpoint><Time>2026-09-24T07:00:00Z</Time><Position><LatitudeDegrees>37.9838</LatitudeDegrees><LongitudeDegrees>23.7275</LongitudeDegrees></Position><DistanceMeters>0</DistanceMeters></Trackpoint>
<Trackpoint><Time>2026-09-24T07:05:00Z</Time><Position><LatitudeDegrees>37.9900</LatitudeDegrees><LongitudeDegrees>23.7275</LongitudeDegrees></Position><DistanceMeters>1000</DistanceMeters></Trackpoint>
</Track></Lap></Activity></Activities></TrainingCenterDatabase>''';
      final run = const TcxImporter().import(tcx);
      final z = RunZone.resolve(run)!;
      expect((z.zoneId, z.offsetMin), ('Europe/Athens', 180));
      expect(_title(run, z), 'Morning'); // 10:00 EEST
    });
  });

  group('sidecar', () {
    test('zone id round-trips and an empty sidecar stays empty', () {
      const id = '11111111-2222-4333-8444-555555555555';
      final s = RunSidecar(runId: id)
          .copyWith(utcOffsetMin: 480, zoneId: 'Asia/Singapore');
      final back = RunSidecarCodec.decode(RunSidecarCodec.encode(s));
      expect((back.utcOffsetMin, back.zoneId), (480, 'Asia/Singapore'));
      expect(RunSidecar(runId: id).isEmpty, isTrue);
      expect(s.isEmpty, isFalse);
    });
  });
}
