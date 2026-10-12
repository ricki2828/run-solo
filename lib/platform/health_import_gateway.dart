/// SPIKE (decision X2 "any watch"): read runs another app wrote to Health
/// Connect. Behind [kHealthConnectImport] (default off); nothing in the app
/// calls this yet, and no UI is wired.
///
/// A plain MethodChannel, not Pigeon: the read side is a spike, and a Pigeon
/// change forces a regenerated `platform_api.g.dart` + `PlatformApi.g.kt`
/// (CI checks they are current) for an API that may be thrown away.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:run_engine/run_engine.dart';

/// Master switch for the importer. Off in every build; tests flip it.
bool kHealthConnectImport = false;

/// A run listed in Health Connect, before any detail is read.
class HealthRunListing {
  const HealthRunListing({
    required this.sessionId,
    required this.startMs,
    required this.endMs,
    required this.sourcePackage,
    this.title,
  });
  final String sessionId;
  final int startMs;
  final int endMs;
  final String sourcePackage;
  final String? title;
}

abstract class HealthImportGateway {
  /// Ask for the read permissions (exercise, distance, heart rate, speed).
  /// Never the route: that is [readRun] with `includeRoute`.
  Future<bool> requestRead();

  /// Running sessions from the last [days] days written by OTHER apps, newest first.
  Future<List<HealthRunListing>> listRuns({int days = 30});

  /// One session's records. [includeRoute] is only ever true from an explicit
  /// tap on that run: Health Connect shows a consent dialog per read and
  /// refuses it in the background. A refused or absent route comes back as an
  /// ordinary routeless session ([HcRunSession.routeConsentRequired]).
  Future<HcRunSession?> readRun(String sessionId, {bool includeRoute = false});
}

class ChannelHealthImportGateway implements HealthImportGateway {
  ChannelHealthImportGateway([MethodChannel? channel])
    : _c = channel ?? const MethodChannel('app.runsolo/health_import');
  final MethodChannel _c;

  @override
  Future<bool> requestRead() async {
    if (!kHealthConnectImport) return false;
    try {
      return await _c.invokeMethod<bool>('requestRead') ?? false;
    } catch (e) {
      debugPrint('health import: permission request failed ($e)');
      return false;
    }
  }

  @override
  Future<List<HealthRunListing>> listRuns({int days = 30}) async {
    if (!kHealthConnectImport) return const [];
    try {
      final raw = await _c.invokeMethod<List<Object?>>('listRuns', {
        'days': days,
      });
      return [
        for (final m in raw ?? const <Object?>[])
          if (m is Map) _listing(m),
      ];
    } catch (e) {
      debugPrint('health import: list failed ($e)');
      return const [];
    }
  }

  @override
  Future<HcRunSession?> readRun(
    String sessionId, {
    bool includeRoute = false,
  }) async {
    if (!kHealthConnectImport) return null;
    try {
      final m = await _c.invokeMapMethod<String, Object?>('readRun', {
        'sessionId': sessionId,
        'includeRoute': includeRoute,
      });
      return m == null ? null : sessionFromMap(m);
    } catch (e) {
      debugPrint('health import: read failed ($e)');
      return null;
    }
  }
}

HealthRunListing _listing(Map<Object?, Object?> m) => HealthRunListing(
  sessionId: m['sessionId']! as String,
  startMs: (m['startMs']! as num).toInt(),
  endMs: (m['endMs']! as num).toInt(),
  sourcePackage: (m['source'] as String?) ?? 'unknown',
  title: m['title'] as String?,
);

/// The channel's map -> [HcRunSession]. Series arrive as flat number lists
/// ([t, v, t, v, ...]) to keep the channel payload small.
@visibleForTesting
HcRunSession sessionFromMap(Map<String, Object?> m) {
  List<num> nums(String k) => [
    for (final v in (m[k] as List?) ?? const []) v as num,
  ];
  List<HcValue> values(String k) {
    final f = nums(k);
    return [
      for (var i = 0; i + 1 < f.length; i += 2)
        HcValue(f[i].toInt(), f[i + 1].toDouble()),
    ];
  }

  final d = nums('distance');
  final r = nums('route');
  return HcRunSession(
    sessionId: m['sessionId']! as String,
    startMs: (m['startMs']! as num).toInt(),
    endMs: (m['endMs']! as num).toInt(),
    zoneOffsetMin: (m['zoneOffsetMin'] as num?)?.toInt(),
    sourcePackage: (m['source'] as String?) ?? 'unknown',
    title: m['title'] as String?,
    distance: [
      for (var i = 0; i + 2 < d.length; i += 3)
        HcDistance(d[i].toInt(), d[i + 1].toInt(), d[i + 2].toDouble()),
    ],
    heartRate: values('heartRate'),
    speed: values('speed'),
    route: [
      // t, lat, lon, alt (NaN when absent)
      for (var i = 0; i + 3 < r.length; i += 4)
        HcRoutePoint(
          r[i].toInt(),
          r[i + 1].toDouble(),
          r[i + 2].toDouble(),
          r[i + 3].isNaN ? null : r[i + 3].toDouble(),
        ),
    ],
    routeConsentRequired: (m['routeConsentRequired'] as bool?) ?? false,
  );
}

class FakeHealthImportGateway implements HealthImportGateway {
  FakeHealthImportGateway({this.runs = const {}, this.grant = true});
  final Map<String, HcRunSession> runs;
  bool grant;
  final List<bool> routeReads = [];

  @override
  Future<bool> requestRead() async => grant;

  @override
  Future<List<HealthRunListing>> listRuns({int days = 30}) async => [
    for (final s in runs.values)
      HealthRunListing(
        sessionId: s.sessionId,
        startMs: s.startMs,
        endMs: s.endMs,
        sourcePackage: s.sourcePackage,
        title: s.title,
      ),
  ];

  @override
  Future<HcRunSession?> readRun(
    String sessionId, {
    bool includeRoute = false,
  }) async {
    routeReads.add(includeRoute);
    return runs[sessionId];
  }
}
