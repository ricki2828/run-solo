import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/run_index.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/state/today_target.dart';
import 'package:run_solo/state/weather.dart';

import '../helpers.dart';

class _Provider implements WeatherProvider {
  _Provider(this.temp, this.dew);
  final num temp, dew;
  final List<Uri> requests = [];

  @override
  Future<WeatherFetch> fetch(Uri uri) async {
    requests.add(uri);
    final h = DateTime.utc(now().year, now().month, now().day, now().hour);
    return WeatherFetched({
      'hourly': {
        'time': [h.toIso8601String().substring(0, 16)],
        'temperature_2m': [temp],
        'relative_humidity_2m': [65],
        'dew_point_2m': [dew],
      },
    });
  }
}

RunSummary run(String id, int daysAgo, double truePace, {bool fix = true}) =>
    RunSummary(
      id: id,
      mode: RecordMode.free,
      start: now().subtract(Duration(days: daysAgo)),
      durationMs: 1800000,
      distanceM: 5000,
      laps: 0,
      startPoint: fix ? (lat: -33.8688, lon: 151.2093) : null,
      row: IndexRow(lapCount: 0, truePaceSecPerKm: truePace),
    );

void main() {
  group('typicalTruePace', () {
    test('median of recent steady runs, null with fewer than two', () {
      expect(typicalTruePace([run('a', 1, 310)], now: now()), isNull);
      expect(
        typicalTruePace([
          run('a', 1, 300),
          run('b', 3, 320),
          run('c', 5, 310),
        ], now: now()),
        310,
      );
    });

    test('ignores old runs and other modes', () {
      final cooper = RunSummary(
        id: 'c',
        mode: RecordMode.cooper,
        start: now().subtract(const Duration(days: 1)),
        durationMs: 720000,
        distanceM: 3000,
        laps: 0,
        row: const IndexRow(lapCount: 0, truePaceSecPerKm: 200),
      );
      expect(
        typicalTruePace([
          run('old', 200, 250),
          run('a', 1, 310),
          run('b', 2, 310),
          cooper,
        ], now: now()),
        310,
      );
    });
  });

  group('Start line', () {
    Future<_Provider> open(
      WidgetTester tester, {
      required num temp,
      required num dew,
      bool weatherOn = true,
      List<RunSummary>? runs,
    }) async {
      final dir = Directory.systemTemp.createTempSync('runsolo-today-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final provider = _Provider(temp, dew);
      final queue = WeatherQueue(
        file: File('${dir.path}/weather-queue.json'),
        store: FileRunStore(Directory('${dir.path}/runs')),
        provider: provider,
        now: now,
        enabled: () => weatherOn,
      );
      await pumpApp(
        tester,
        fakeServices(
          weather: queue,
          runs: runs ?? [run('a', 1, 310), run('b', 3, 310)],
          settings: const AppSettings(
            onboardingDone: true,
            lastMode: RecordMode.free,
          ),
        ),
        pushRoute: Routes.start,
      );
      await pumpTimes(tester, 6);
      return provider;
    }

    String? line(WidgetTester tester) {
      final f = find.byKey(const ValueKey('today-target'));
      return f.evaluate().isEmpty ? null : tester.widget<Text>(f).data;
    }

    testWidgets('a warm day shows the aim and the actual pace', (tester) async {
      final provider = await open(tester, temp: 31, dew: 22);
      final text = line(tester)!;
      expect(text, startsWith('Warm today (31°C). Aim for 5:10/km true pace'));
      expect(text, matches(RegExp(r'about 5:[23]\d/km actual\.$')));
      expect(provider.requests.single.queryParameters['latitude'], '-33.9');
    });

    testWidgets('a cool day has no line', (tester) async {
      await open(tester, temp: 12, dew: 5);
      expect(line(tester), isNull);
    });

    testWidgets('weather off: no request, no line', (tester) async {
      final provider = await open(tester, temp: 31, dew: 22, weatherOn: false);
      expect(line(tester), isNull);
      expect(provider.requests, isEmpty);
    });

    testWidgets('no recent pace, no line', (tester) async {
      await open(tester, temp: 31, dew: 22, runs: [run('a', 1, 310)]);
      expect(line(tester), isNull);
    });

    testWidgets('no outdoor run to place the weather, no request', (
      tester,
    ) async {
      final provider = await open(
        tester,
        temp: 31,
        dew: 22,
        runs: [run('a', 1, 310, fix: false), run('b', 2, 310, fix: false)],
      );
      expect(line(tester), isNull);
      expect(provider.requests, isEmpty);
    });
  });
}
