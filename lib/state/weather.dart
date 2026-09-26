/// Weather for finished runs (v1 plan §18.5, Phase 3 W1).
///
/// After a run is finalised (never during one) its id goes into
/// `files/state/weather-queue.json`. On each app open (and after any
/// successful fetch) the queue is drained, one attempt per run:
/// - indoor (no fix) → `skipped`, nothing sent;
/// - offline, timeout or 5xx → stays queued, the rest of the pass stops (it
///   would only time out again);
/// - the hour not served yet, or a null value → `pending`, stays queued;
/// - 4xx → `failed` ("Weather unavailable"), never retried;
/// - otherwise → `ok` with temperature, humidity, dew point and the heat
///   adjustment.
/// Every result is written to the run's sidecar through the one
/// [SidecarWriter] (and never recreates a deleted run's sidecar). The
/// request carries the run's first fix rounded to 0.1° and the dates only;
/// only the rounded pair is stored. Verdicts are computed and frozen
/// without weather; weather only adds the adjusted line (W2 decides what
/// the "compare heat-adjusted" setting does with it).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:run_engine/run_engine.dart' as engine;

import 'history_store.dart';

/// Outcome of one HTTP fetch.
sealed class WeatherFetch {
  const WeatherFetch();
}

class WeatherFetched extends WeatherFetch {
  const WeatherFetched(this.body);
  final Map<String, Object?> body;
}

/// Offline, timeout, 5xx, 408, 429 or an unreadable body: try again later.
class WeatherRetryLater extends WeatherFetch {
  const WeatherRetryLater(this.reason, {this.retryAfter});
  final String reason;

  /// The provider's `Retry-After` (or a default for a 429): nothing is sent
  /// before it has passed.
  final Duration? retryAfter;
}

/// Any other 4xx: the provider will never serve this request.
class WeatherRejected extends WeatherFetch {
  const WeatherRejected(this.statusCode);
  final int statusCode;
}

/// The seam for a paid provider (v1 plan §14, W8): Open-Meteo's free API is
/// for non-commercial use; the paid product swaps this implementation.
abstract class WeatherProvider {
  Future<WeatherFetch> fetch(Uri uri);
}

/// Open-Meteo over HTTPS: no key, no identifier, 10 s timeout.
class OpenMeteoProvider implements WeatherProvider {
  const OpenMeteoProvider({this.timeout = const Duration(seconds: 10)});

  final Duration timeout;

  @override
  Future<WeatherFetch> fetch(Uri uri) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client.getUrl(uri).timeout(timeout);
      final res = await req.close().timeout(timeout);
      final text = await res.transform(utf8.decoder).join().timeout(timeout);
      final code = res.statusCode;
      if (code >= 500 || code == 408 || code == 429) {
        return WeatherRetryLater(
          '$code',
          retryAfter:
              retryAfterOf(res.headers.value('retry-after'), DateTime.now()) ??
              (code == 429 ? const Duration(minutes: 1) : null),
        );
      }
      if (code >= 400) return WeatherRejected(code);
      final body = jsonDecode(text);
      if (body is! Map<String, Object?>) {
        return const WeatherRetryLater('not an object');
      }
      return WeatherFetched(body);
    } on TimeoutException {
      return const WeatherRetryLater('timeout');
    } on SocketException catch (e) {
      return WeatherRetryLater('offline (${e.message})');
    } on HandshakeException catch (e) {
      return WeatherRetryLater('tls (${e.message})');
    } on HttpException catch (e) {
      return WeatherRetryLater('http (${e.message})');
    } on FormatException {
      return const WeatherRetryLater('bad json');
    } finally {
      client.close(force: true);
    }
  }
}

/// `Retry-After` as seconds or an HTTP date; null when absent or unreadable.
Duration? retryAfterOf(String? header, DateTime now) {
  if (header == null) return null;
  final secs = int.tryParse(header.trim());
  if (secs != null) return secs < 0 ? null : Duration(seconds: secs);
  try {
    final at = HttpDate.parse(header.trim());
    final d = at.difference(now.toUtc());
    return d.isNegative ? Duration.zero : d;
  } on FormatException {
    return null;
  } on HttpException {
    return null;
  }
}

/// What one [WeatherQueue.drain] pass did (for tests and logs).
@immutable
class WeatherDrainResult {
  const WeatherDrainResult({
    this.ok = const [],
    this.pending = const [],
    this.failed = const [],
    this.skipped = const [],
    this.stoppedEarly = false,
  });
  final List<String> ok;
  final List<String> pending;
  final List<String> failed;
  final List<String> skipped;

  /// A retryable error, a Retry-After still running, or the per-pass cap
  /// ended the pass; the rest wait for the next pass.
  final bool stoppedEarly;
}

class WeatherQueue {
  WeatherQueue({
    required this.file,
    required this.store,
    required this.provider,
    DateTime Function()? now,
    bool Function()? enabled,
    this.constants = engine.EngineConstants.defaults,
  }) : now = now ?? DateTime.now,
       enabled = enabled ?? (() => true);

  /// `files/state/weather-queue.json`.
  final File file;
  final FileRunStore store;
  final WeatherProvider provider;
  final DateTime Function() now;

  /// The "Weather for each run" setting; off = nothing is fetched or queued.
  final bool Function() enabled;
  final engine.EngineConstants constants;

  static const String _key = 'weather-queue.json';

  /// Requests per pass: the first open after this update backfills every
  /// old run, spread over opens instead of one burst.
  static const int maxRequestsPerPass = 30;

  bool _draining = false;

  /// Nothing is sent before this (the provider's Retry-After).
  DateTime? _notBefore;

  Future<List<String>> queued() async {
    try {
      if (!await file.exists()) return const [];
      final j = jsonDecode(await file.readAsString());
      if (j is! Map || j['schema'] != 1 || j['ids'] is! List) return const [];
      return [for (final id in j['ids'] as List) id as String];
    } catch (e) {
      debugPrint('weather: queue unreadable, starting again ($e)');
      return const [];
    }
  }

  Future<void> _edit(List<String> Function(List<String> ids) change) =>
      store.sidecars.replaceText(_key, file, (current) {
        List<String> ids = const [];
        try {
          final j = current == null ? null : jsonDecode(current);
          if (j is Map && j['schema'] == 1 && j['ids'] is List) {
            ids = [for (final id in j['ids'] as List) id as String];
          }
        } catch (_) {}
        final next = change(ids);
        return jsonEncode({'schema': 1, 'ids': next});
      });

  /// Queue a finished run (idempotent).
  Future<void> enqueue(String runId) async {
    if (!enabled()) return;
    await _edit((ids) => ids.contains(runId) ? ids : [...ids, runId]);
  }

  /// Queue every run that has no weather yet, or is still pending (a run
  /// imported, or finalised while the app was not running).
  Future<void> reconcile() async {
    if (!enabled()) return;
    final missing = <String>[];
    for (final (run, sidecar) in await store.weatherCandidates()) {
      final w = engine.WeatherRecord.fromJson(sidecar?.weather);
      if (w == null || w.status == engine.WeatherStatus.pending) {
        missing.add(run.id);
      }
    }
    if (missing.isEmpty) return;
    await _edit((ids) => [...ids, ...missing.where((m) => !ids.contains(m))]);
  }

  /// One attempt per queued run (app open, and after a successful fetch).
  Future<WeatherDrainResult> drain() async {
    if (!enabled() || _draining) return const WeatherDrainResult();
    _draining = true;
    try {
      return await _drain();
    } finally {
      _draining = false;
    }
  }

  Future<WeatherDrainResult> _drain() async {
    final ids = await queued();
    if (ids.isEmpty) return const WeatherDrainResult();
    final wait = _notBefore;
    if (wait != null && now().isBefore(wait)) {
      return const WeatherDrainResult(stoppedEarly: true);
    }
    var requests = 0;
    final runs = {
      for (final (run, sidecar) in await store.weatherCandidates())
        run.id: (run, sidecar),
    };
    final ok = <String>[], pending = <String>[];
    final failed = <String>[], skipped = <String>[];
    final done = <String>{};
    var stopped = false;
    for (final id in ids) {
      final entry = runs[id];
      if (entry == null) {
        done.add(id); // deleted since it was queued
        continue;
      }
      final (run, sidecar) = entry;
      final have = engine.WeatherRecord.fromJson(sidecar?.weather);
      if (have != null && have.status != engine.WeatherStatus.pending) {
        done.add(id);
        continue;
      }
      final t = now();
      final indoor =
          engine.Trace(run.samples).fixShare() < constants.indoorFixShareBelow;
      final request = indoor ? null : engine.WeatherRequest.forRun(run, now: t);
      if (request == null) {
        await store.setWeather(
          id,
          engine.WeatherRecord(
            status: engine.WeatherStatus.skipped,
            fetchedAt: t.toUtc(),
          ),
        );
        skipped.add(id);
        done.add(id);
        continue;
      }
      if (requests == maxRequestsPerPass) {
        stopped = true;
        break;
      }
      requests++;
      final result = await provider.fetch(request.uri);
      switch (result) {
        case WeatherRetryLater(:final reason, :final retryAfter):
          debugPrint('weather: $id waits ($reason)');
          if (retryAfter != null) _notBefore = now().add(retryAfter);
          stopped = true;
        case WeatherRejected(:final statusCode):
          await store.setWeather(
            id,
            engine.WeatherRecord(
              status: engine.WeatherStatus.failed,
              fetchedAt: t.toUtc(),
              latR: request.location.lat,
              lonR: request.location.lon,
            ),
          );
          debugPrint('weather: $id failed ($statusCode)');
          failed.add(id);
          done.add(id);
        case WeatherFetched(:final body):
          final record = request.parse(body, now: t);
          await store.setWeather(id, record);
          if (record.isOk) {
            ok.add(id);
            done.add(id);
          } else {
            pending.add(id);
          }
      }
      if (stopped) break;
    }
    if (done.isNotEmpty) {
      await _edit(
        (ids) => [
          for (final i in ids)
            if (!done.contains(i)) i,
        ],
      );
    }
    return WeatherDrainResult(
      ok: ok,
      pending: pending,
      failed: failed,
      skipped: skipped,
      stoppedEarly: stopped,
    );
  }
}
