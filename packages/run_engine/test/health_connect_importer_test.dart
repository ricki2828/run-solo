import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

/// A 15 min, 3 km run at 5:00/km: one distance record a minute, heart rate
/// every 5 s climbing 140 -> 170 bpm. [withRoute] adds a GPS point every 5 s
/// heading north.
HcRunSession session({bool withRoute = false, bool withDistance = true}) {
  const startMs = 1790000000000;
  const durMs = 15 * 60 * 1000;
  return HcRunSession(
    sessionId: 'hc-record-1',
    startMs: startMs,
    endMs: startMs + durMs,
    zoneOffsetMin: 480,
    sourcePackage: 'com.garmin.android.apps.connectmobile',
    title: 'Morning run',
    distance: withDistance
        ? [
            for (var m = 0; m < 15; m++)
              HcDistance(startMs + m * 60000, startMs + (m + 1) * 60000, 200),
          ]
        : const [],
    heartRate: [
      for (var t = 0; t <= durMs; t += 5000)
        HcValue(startMs + t, 140 + 30 * t / durMs),
    ],
    route: withRoute
        ? [
            for (var t = 0; t <= durMs; t += 5000)
              // 3.333 m/s north; one degree of latitude is about 111195 m.
              HcRoutePoint(
                startMs + t,
                1.30 + (t / 1000) * 3.3333 / 111195,
                103.8,
                12,
              ),
          ]
        : const [],
  );
}

void main() {
  const importer = HealthConnectImporter();

  test('no route (first-class case): distance, HR and time carry over', () {
    final run = importer.import(session());
    expect(run.app, 'import:healthconnect');
    expect(run.device, 'com.garmin.android.apps.connectmobile');
    expect(run.tz, '+08:00');
    expect(run.mode, RunMode.free);
    expect(run.elapsedMs, 15 * 60 * 1000);
    expect(run.distanceM, closeTo(3000, 0.5));
    expect(run.hasHr, isTrue);
    expect(run.samples.any((s) => s.hasFix), isFalse);
    expect(run.samples.first.tMs, 0);
    for (var i = 1; i < run.samples.length; i++) {
      expect(run.samples[i].tMs, greaterThan(run.samples[i - 1].tMs));
      expect(
        run.samples[i].distM,
        greaterThanOrEqualTo(run.samples[i - 1].distM),
      );
    }
    expect(run.samples[60].speedMps, closeTo(3.33, 0.05));
  });

  test('with route: ticks carry a fix and the run survives a round trip', () {
    final run = importer.import(session(withRoute: true));
    expect(run.samples.every((s) => s.hasFix), isTrue);
    expect(run.samples[10].altM, 12);
    final back = RunFile.fromJson(run.toJson());
    expect(back.samples.length, run.samples.length);
    expect(back.id, run.id);
  });

  test('route only (no distance records): haversine distance', () {
    final run = importer.import(session(withRoute: true, withDistance: false));
    expect(run.distanceM, closeTo(3000, 15));
  });

  test('same session imports to the same id, another does not', () {
    final a = importer.import(session()).id;
    expect(importer.import(session()).id, a);
    expect(RunFile.uuidPattern.hasMatch(a), isTrue);
    expect(HealthConnectImporter.runIdFor('other'), isNot(a));
  });

  test('nothing to measure is refused, not guessed', () {
    expect(
      () => importer.import(session(withDistance: false)),
      throwsA(isA<ImportFormatException>()),
    );
    expect(
      () => importer.import(
        const HcRunSession(sessionId: 'x', startMs: 1000, endMs: 1500),
      ),
      throwsA(isA<ImportFormatException>()),
    );
  });

  test('companion fields: splits without a route', () {
    final noRoute = companionShapeFields(importer.import(session()));
    expect(noRoute.containsKey('route'), isFalse);
    expect((noRoute['splits'] as List).length, 3);
    final withRoute = companionShapeFields(
      importer.import(session(withRoute: true)),
    );
    expect(withRoute['splits'], isA<List>());
    expect(
      withRoute.keys.toSet().difference({'route', 'splits', 'reps'}),
      isEmpty,
    );
  });

  test('analysis runs on an imported run', () {
    final run = importer.import(session(withRoute: true));
    final a = const RunEngine().analyze(run, now: DateTime.utc(2026, 10, 12));
    expect(a, isNotNull);
  });
}
