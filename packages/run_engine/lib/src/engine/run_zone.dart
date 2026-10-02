import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone_finder/timezone_finder.dart' as finder;

import '../model/run_file.dart';
import 'run_identity.dart';

/// The wall-clock zone a run started in: an IANA id when one is known, and
/// the UTC offset in minutes at the run's start instant (DST-correct).
typedef RunLocalZone = ({String? zoneId, int offsetMin});

/// Works out WHERE a run started so its time of day is the clock there, not
/// the phone's current zone. Offline: the start fix goes through compiled-in
/// zone boundaries (package:timezone_finder), the zone's rules give the
/// offset at that instant (package:timezone).
abstract final class RunZone {
  static bool _ready = false;

  static void _init() {
    if (_ready) return;
    tzdata.initializeTimeZones();
    _ready = true;
  }

  /// The IANA zone covering ([lat], [lon]); null at sea or on any lookup
  /// failure. Never throws.
  static String? zoneAt(double lat, double lon) {
    try {
      _init();
      return finder.findLocation(lon, lat)?.name;
    } catch (_) {
      return null;
    }
  }

  /// [zoneId]'s UTC offset in minutes at [instant]; null for an id the zone
  /// database does not know. Never throws.
  static int? offsetAt(String zoneId, DateTime instant) {
    try {
      _init();
      final zone = tz
          .getLocation(zoneId)
          .timeZone(instant.toUtc().millisecondsSinceEpoch);
      return zone.offset.inMinutes;
    } catch (_) {
      return null;
    }
  }

  /// The zone [run] started in, best evidence first:
  /// 1. [zoneId], already worked out and stored in the sidecar;
  /// 2. the start fix (any run with a GPS fix, imported or not);
  /// 3. the run file's `tz`, the phone's zone when the run began (not for an
  ///    import, whose `tz` is a placeholder, and a bare "UTC" is no evidence);
  /// 4. [stampedOffsetMin], the phone's offset stamped at finish.
  /// Null when none is available: the caller then falls back to the phone's
  /// current zone, which is only right for a run that has no better record.
  static RunLocalZone? resolve(
    RunFile run, {
    String? zoneId,
    int? stampedOffsetMin,
  }) {
    RunLocalZone? from(String? id) {
      if (id == null) return null;
      final m = offsetAt(id, run.start);
      return m == null ? null : (zoneId: id, offsetMin: m);
    }

    final stored = from(zoneId);
    if (stored != null) return stored;
    final fix = RunIdentity.startOf(run);
    if (fix != null) {
      final fromFix = from(zoneAt(fix.lat, fix.lon));
      if (fromFix != null) return fromFix;
    }
    // A bare "UTC" is what a placeholder looks like (no phone reports it for
    // a real place), so it is no evidence.
    final utcLike = const {'UTC', 'Etc/UTC', 'GMT', 'Etc/GMT'}.contains(run.tz);
    if (!run.app.startsWith('import:') && !utcLike) {
      final fromFile = from(run.tz);
      if (fromFile != null) return fromFile;
    }
    return stampedOffsetMin == null
        ? null
        : (zoneId: null, offsetMin: stampedOffsetMin);
  }
}
