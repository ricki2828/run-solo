import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

RunFile treadmill({double? distance = 5200}) => RunFile(
  id: '00000000-0000-4000-8000-0000000000ab',
  device: 'phone',
  app: 'test',
  start: DateTime.utc(2026, 11, 2),
  end: DateTime.utc(2026, 11, 2, 0, 30),
  tz: 'UTC',
  mode: RunMode.treadmill,
  units: Units.km,
  laps: const [],
  treadmillDistanceM: distance,
  samples: [
    for (var i = 0; i <= 1800; i++)
      Sample(
        tMs: i * 1000,
        lat: null,
        lon: null,
        altM: null,
        accM: null,
        speedMps: null,
        distM: 0,
        hr: 145,
      ),
  ],
);

void main() {
  test('manual distance roundtrips without manufacturing GPS or splits', () {
    final run = RunFileCodec.decode(RunFileCodec.encode(treadmill()));
    expect(run.writeSchema, 9);
    expect(run.mode, RunMode.treadmill);
    expect(run.distanceM, 5200);
    expect(run.elapsedMs, 1800000);
    expect(run.samples.every((s) => !s.hasFix && s.distM == 0), isTrue);
    final a = const RunEngine().analyze(run);
    expect(a.freeRun.distanceM, 5200);
    expect(a.freeRun.avgHr, 145);
    expect(a.freeRun.splitsSecPerUnit, isEmpty);
    expect(a.indoor, isTrue);
    expect(a.verdict, isNull);
    expect(a.truePace, isNull);
    expect(a.cooper, isNull);
    expect(a.eligibleAsPrior, isFalse);
  });

  test('invalid distance and distance on an outdoor run are rejected', () {
    for (final bad in [-1, 0, double.nan, double.infinity, 500001]) {
      final json = treadmill().toJson()..['treadmillDistanceM'] = bad;
      expect(
        () => RunFile.fromJson(json),
        throwsA(isA<RunFileFormatException>()),
      );
    }
    final json = treadmill().toJson()..['mode'] = 'free';
    expect(
      () => RunFile.fromJson(json),
      throwsA(isA<RunFileFormatException>()),
    );
    // A killed recording may be recovered before distance was entered.
    expect(
      RunFileCodec.decode(RunFileCodec.encode(treadmill(distance: null)))
          .distanceM,
      0,
    );
  });

  test('TCX carries aggregate distance, HR, time and treadmill identity', () {
    final xml = const TcxExporter().export(treadmill());
    final doc = XmlDocument.parse(xml);
    expect(doc.findAllElements('Position'), isEmpty);
    expect(doc.findAllElements('DistanceMeters').map((e) => e.innerText), [
      '5200.0',
    ]);
    expect(doc.findAllElements('HeartRateBpm'), hasLength(1801));
    expect(doc.findAllElements('TotalTimeSeconds').single.innerText, '1800.0');
    final imported = const TcxImporter().import(xml);
    expect(imported.id, '00000000-0000-4000-8000-0000000000ab');
    expect(imported.mode, RunMode.treadmill);
    expect(imported.distanceM, 5200);
    expect(imported.samples.every((s) => !s.hasFix && s.distM == 0), isTrue);
  });

  test('out of range TCX distance does not make an unreadable run', () {
    final xml = const TcxExporter().export(treadmill());
    for (final distance in ['0.0', '500001.0']) {
      final imported = const TcxImporter().import(
        xml.replaceFirst(
          '<DistanceMeters>5200.0</DistanceMeters>',
          '<DistanceMeters>$distance</DistanceMeters>',
        ),
      );
      expect(imported.mode, RunMode.treadmill);
      expect(imported.treadmillDistanceM, isNull);
      expect(
        () => RunFileCodec.decode(RunFileCodec.encode(imported)),
        returnsNormally,
      );
    }
  });

  test('GPX carries treadmill metadata with no invented route', () {
    final doc = XmlDocument.parse(const GpxExporter().export(treadmill()));
    expect(doc.findAllElements('trkpt'), isEmpty);
    expect(doc.findAllElements('type').single.innerText, 'treadmill');
    expect(doc.findAllElements('desc').single.innerText, contains('5200'));
  });
}
