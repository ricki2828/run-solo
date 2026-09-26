import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/sidecar_writer.dart';
import 'package:run_solo/state/weather.dart';

import '../run_fixtures.dart';

/// Scripted provider: records every URI, answers from a queue of results
/// (the last one repeats).
class FakeWeatherProvider implements WeatherProvider {
  FakeWeatherProvider(this.answers);
  final List<WeatherFetch Function(Uri uri)> answers;
  final List<Uri> requests = [];

  @override
  Future<WeatherFetch> fetch(Uri uri) async {
    requests.add(uri);
    final a = answers.length > 1 ? answers.removeAt(0) : answers.single;
    return a(uri);
  }
}

/// An Open-Meteo body with one hour at the run's midpoint.
WeatherFetch hourAt(engine.RunFile run, {num? temp = 28, num? dew = 21}) {
  final mid = run.start.add(
    Duration(milliseconds: run.end.difference(run.start).inMilliseconds ~/ 2),
  );
  final h = DateTime.utc(mid.year, mid.month, mid.day, mid.hour);
  return WeatherFetched({
    'hourly': {
      'time': [h.toIso8601String().substring(0, 16)],
      'temperature_2m': [temp],
      'relative_humidity_2m': [65],
      'dew_point_2m': [dew],
    },
  });
}

void main() {
  final d1 = DateTime.utc(2026, 9, 10, 6);
  late Directory dir;
  late Directory runsDir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('runsolo-weather-');
    runsDir = Directory('${dir.path}/runs');
  });
  tearDown(() => dir.delete(recursive: true));

  Future<(FileRunStore, WeatherQueue, FakeWeatherProvider)> setup(
    List<engine.RunFile> runs,
    List<WeatherFetch Function(Uri)> answers, {
    bool Function()? enabled,
  }) async {
    final store = FileRunStore(runsDir);
    await store.importBundles([for (final r in runs) engine.RunBundle(run: r)]);
    final provider = FakeWeatherProvider(answers);
    final q = WeatherQueue(
      file: File('${dir.path}/state/weather-queue.json'),
      store: store,
      provider: provider,
      now: () => d1.add(const Duration(days: 1)),
      enabled: enabled,
    );
    return (store, q, provider);
  }

  Future<engine.WeatherRecord?> weatherOf(String id) async =>
      engine.WeatherRecord.fromJson(
        (await SidecarWriter.read(File('${runsDir.path}/run-$id.edits.json')))
            ?.weather,
      );

  test('offline → stays queued; next open fetches once with 0.1° '
      'coordinates, sidecar ok, index updated', () async {
    final r = fourByFourFile(n: 1, start: d1);
    final (store, q, provider) = await setup(
      [r],
      [(_) => const WeatherRetryLater('offline'), (_) => hourAt(r)],
    );
    await q.enqueue(r.id);
    final first = await q.drain();
    expect(first.stoppedEarly, isTrue);
    expect(await q.queued(), [r.id]);
    expect(await weatherOf(r.id), isNull, reason: 'nothing written offline');

    final second = await q.drain();
    expect(second.ok, [r.id]);
    expect(await q.queued(), isEmpty);
    expect(provider.requests, hasLength(2));
    final uri = provider.requests.last;
    for (final k in ['latitude', 'longitude']) {
      expect(
        RegExp(r'^-?\d+\.\d$').hasMatch(uri.queryParameters[k]!),
        isTrue,
        reason: '$k=${uri.queryParameters[k]}',
      );
    }
    final w = (await weatherOf(r.id))!;
    expect(w.status, engine.WeatherStatus.ok);
    expect(w.tempC, 28);
    expect(w.adj, closeTo(0.047, 0.0005));
    // Only the rounded pair is stored.
    expect(w.latR, double.parse(uri.queryParameters['latitude']!));
    expect(w.lonR, double.parse(uri.queryParameters['longitude']!));
    final firstFix = r.samples.firstWhere((s) => s.hasFix);
    expect(w.latR, isNot(firstFix.lat));

    await store.list();
    final entry = (await store.readIndex()).entries[r.id]!;
    expect(entry.weatherStatus, engine.WeatherStatus.ok);
    expect(entry.tempC, 28);
    expect(entry.dewPointC, 21);
    expect(entry.heatAdj, closeTo(0.047, 0.0005));
  });

  test('4xx → failed, never retried', () async {
    final r = fourByFourFile(n: 1, start: d1);
    final (_, q, provider) = await setup(
      [r],
      [(_) => const WeatherRejected(404)],
    );
    await q.enqueue(r.id);
    expect((await q.drain()).failed, [r.id]);
    expect((await weatherOf(r.id))!.status, engine.WeatherStatus.failed);
    expect(await q.queued(), isEmpty);
    await q.reconcile();
    await q.drain();
    expect(provider.requests, hasLength(1), reason: 'no retry');
  });

  test('null hourly value → pending, still queued, no adj', () async {
    final r = fourByFourFile(n: 1, start: d1);
    final (_, q, _) = await setup([r], [(_) => hourAt(r, temp: null)]);
    await q.enqueue(r.id);
    expect((await q.drain()).pending, [r.id]);
    final w = (await weatherOf(r.id))!;
    expect(w.status, engine.WeatherStatus.pending);
    expect(w.adj, isNull);
    expect(await q.queued(), [r.id]);
  });

  test('indoor run → skipped, nothing sent', () async {
    final r = fourByFourFile(n: 1, start: d1, indoor: true);
    final (_, q, provider) = await setup([r], [(_) => hourAt(r)]);
    await q.enqueue(r.id);
    expect((await q.drain()).skipped, [r.id]);
    expect(provider.requests, isEmpty);
    final w = (await weatherOf(r.id))!;
    expect(w.status, engine.WeatherStatus.skipped);
    expect(w.latR, isNull);
  });

  test('the verdict frozen before the fetch is unchanged after it', () async {
    final r = fourByFourFile(n: 1, start: d1);
    final (store, q, _) = await setup([r], [(_) => hourAt(r)]);
    await store.list(); // freezes the verdict
    final before = (await SidecarWriter.read(
      File('${runsDir.path}/run-${r.id}.edits.json'),
    ))!.frozenVerdict!;
    await q.enqueue(r.id);
    await q.drain();
    await store.list();
    final after = (await SidecarWriter.read(
      File('${runsDir.path}/run-${r.id}.edits.json'),
    ))!;
    expect(after.frozenVerdict!.toJson(), before.toJson());
    expect(after.verdictHistory, isEmpty);
    expect(engine.WeatherRecord.fromJson(after.weather)!.isOk, isTrue);
  });

  test('a weather write interleaved with a fix-laps edit: both survive '
      '(v1 plan W5)', () async {
    final synthetic = fourByFourSynthetic(n: 1, start: d1, missedPress: true);
    final r = synthetic.run;
    final (store, q, _) = await setup([r], [(_) => hourAt(r)]);
    final gate = Completer<void>();
    var holds = 0;
    store.sidecars.afterRead = (id) async {
      // Hold the first write (the weather one) after its read.
      if (holds++ == 0) await gate.future;
    };
    await q.enqueue(r.id);
    final weather = q.drain();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final edits = Future.wait([
      for (final e in synthetic.expected.rescueEdits)
        store.applyLapEdit(r.id, e),
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    gate.complete();
    await Future.wait([weather, edits]);
    store.sidecars.afterRead = null;
    final s = (await SidecarWriter.read(
      File('${runsDir.path}/run-${r.id}.edits.json'),
    ))!;
    expect(s.lapEdits.length, synthetic.expected.rescueEdits.length);
    expect(engine.WeatherRecord.fromJson(s.weather)!.isOk, isTrue);
  });

  test('429 waits for Retry-After, then fetches; never failed', () async {
    final r = fourByFourFile(n: 1, start: d1);
    final store = FileRunStore(runsDir);
    await store.importBundles([engine.RunBundle(run: r)]);
    var clock = d1.add(const Duration(days: 1));
    final provider = FakeWeatherProvider([
      (_) => const WeatherRetryLater('429', retryAfter: Duration(seconds: 120)),
      (_) => hourAt(r),
    ]);
    final q = WeatherQueue(
      file: File('${dir.path}/state/weather-queue.json'),
      store: store,
      provider: provider,
      now: () => clock,
    );
    await q.enqueue(r.id);
    expect((await q.drain()).stoppedEarly, isTrue);
    expect(await weatherOf(r.id), isNull, reason: 'not failed');
    expect(await q.queued(), [r.id]);
    clock = clock.add(const Duration(seconds: 60));
    expect((await q.drain()).stoppedEarly, isTrue);
    expect(provider.requests, hasLength(1), reason: 'nothing sent early');
    clock = clock.add(const Duration(seconds: 61));
    expect((await q.drain()).ok, [r.id]);
    expect(provider.requests, hasLength(2));
  });

  test('Retry-After: seconds or an HTTP date', () {
    final now = DateTime.utc(2026, 9, 26, 6);
    expect(retryAfterOf('120', now), const Duration(seconds: 120));
    expect(
      retryAfterOf('Sat, 26 Sep 2026 06:02:00 GMT', now),
      const Duration(minutes: 2),
    );
    expect(retryAfterOf('soon', now), isNull);
    expect(retryAfterOf(null, now), isNull);
  });

  test('the first-open backfill is spread over passes', () async {
    final runs = [
      for (var i = 0; i < WeatherQueue.maxRequestsPerPass + 5; i++)
        fourByFourFile(
          n: i + 1,
          start: d1.add(Duration(hours: i)),
        ),
    ];
    final (_, q, provider) = await setup(runs, [
      (uri) => const WeatherRejected(404),
    ]);
    for (final r in runs) {
      await q.enqueue(r.id);
    }
    final first = await q.drain();
    expect(provider.requests, hasLength(WeatherQueue.maxRequestsPerPass));
    expect(first.stoppedEarly, isTrue);
    expect(await q.queued(), hasLength(5));
    await q.drain();
    expect(provider.requests, hasLength(WeatherQueue.maxRequestsPerPass + 5));
    expect(await q.queued(), isEmpty);
  });

  test('one retryable error stops the pass: no 10 s timeout per run', () async {
    final r1 = fourByFourFile(n: 1, start: d1);
    final r2 = fourByFourFile(n: 2, start: d1.add(const Duration(days: 1)));
    final (_, q, provider) = await setup(
      [r1, r2],
      [(_) => const WeatherRetryLater('timeout')],
    );
    await q.enqueue(r1.id);
    await q.enqueue(r2.id);
    await q.drain();
    expect(provider.requests, hasLength(1));
    expect(await q.queued(), [r1.id, r2.id]);
  });

  test('reconcile queues runs with no weather yet; a deleted run drops out '
      'without recreating its sidecar', () async {
    final r1 = fourByFourFile(n: 1, start: d1);
    final r2 = fourByFourFile(n: 2, start: d1.add(const Duration(days: 1)));
    final (store, q, provider) = await setup([r1, r2], [(u) => hourAt(r2)]);
    await q.reconcile();
    expect((await q.queued()).toSet(), {r1.id, r2.id});
    await store.delete(r1.id);
    await q.drain();
    expect(await q.queued(), isEmpty);
    expect(
      File('${runsDir.path}/run-${r1.id}.edits.json').existsSync(),
      isFalse,
    );
    expect(provider.requests, hasLength(1));
  });

  test('"Weather for each run" off: nothing queued, nothing sent', () async {
    final r = fourByFourFile(n: 1, start: d1);
    final (_, q, provider) = await setup(
      [r],
      [(_) => hourAt(r)],
      enabled: () => false,
    );
    await q.enqueue(r.id);
    await q.reconcile();
    await q.drain();
    expect(await q.queued(), isEmpty);
    expect(provider.requests, isEmpty);
  });
}
