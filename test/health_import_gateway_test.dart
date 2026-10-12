import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart';
import 'package:run_solo/platform/health_import_gateway.dart';

void main() {
  tearDown(() => kHealthConnectImport = false);

  test('the flag is off by default and the gateway is inert', () async {
    expect(kHealthConnectImport, isFalse);
    final g = ChannelHealthImportGateway();
    expect(await g.requestRead(), isFalse);
    expect(await g.listRuns(), isEmpty);
    expect(await g.readRun('x'), isNull);
  });

  test('channel map -> session -> run file, routeless and routed', () {
    final routeless = sessionFromMap({
      'sessionId': 's1',
      'startMs': 1000000,
      'endMs': 1000000 + 600000,
      'zoneOffsetMin': 120,
      'source': 'com.sec.android.app.shealth',
      'distance': [1000000, 1600000, 2000.0],
      'heartRate': [1000000, 150.0, 1300000, 160.0],
      'speed': <num>[],
      'route': <num>[],
      'routeConsentRequired': true,
    });
    expect(routeless.routeConsentRequired, isTrue);
    final run = const HealthConnectImporter().import(routeless);
    expect(run.distanceM, closeTo(2000, 0.5));
    expect(run.samples.any((s) => s.hasFix), isFalse);
    expect(run.tz, '+02:00');

    final routed = sessionFromMap({
      'sessionId': 's2',
      'startMs': 0,
      'endMs': 60000,
      'distance': <num>[],
      'route': [0, 1.0, 103.0, double.nan, 60000, 1.001, 103.0, 5.0],
    });
    expect(routed.route.first.altM, isNull);
    expect(routed.route.last.altM, 5.0);
    expect(
      const HealthConnectImporter().import(routed).distanceM,
      closeTo(111, 2),
    );
  });

  test('the fake never reads a route unless asked', () async {
    const s = HcRunSession(sessionId: 's', startMs: 0, endMs: 5000);
    final g = FakeHealthImportGateway(runs: {'s': s});
    expect(await g.listRuns(), hasLength(1));
    await g.readRun('s');
    expect(g.routeReads, [false]);
  });
}
