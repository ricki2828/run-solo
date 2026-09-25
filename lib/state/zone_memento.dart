/// The last HR zone of the live run, persisted so a recreated isolate
/// (task swipe with the service still recording, then reopen from the
/// notification) paints that zone on its first frame instead of black
/// (plan §18.1 W4). `status()` carries no HR, so this is the only source
/// after a process restart. Written only when the zone changes (≤ once
/// per 5 s by the tracker's rules), cleared on stop.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

@immutable
class ZoneMemento {
  const ZoneMemento({
    required this.runId,
    required this.zone,
    required this.hr,
    required this.elapsedMs,
  });
  final String runId;
  final int zone;
  final int? hr;
  final int elapsedMs;

  Map<String, Object?> toJson() => {
    'runId': runId,
    'zone': zone,
    'hr': hr,
    'elapsedMs': elapsedMs,
  };

  static ZoneMemento? fromJson(Object? j) {
    if (j is! Map<String, Object?>) return null;
    final runId = j['runId'];
    final zone = j['zone'];
    final elapsed = j['elapsedMs'];
    if (runId is! String || zone is! int || elapsed is! int) return null;
    return ZoneMemento(
      runId: runId,
      zone: zone.clamp(0, 5),
      hr: j['hr'] is int ? j['hr'] as int : null,
      elapsedMs: elapsed,
    );
  }
}

abstract class ZoneMementoStore {
  Future<ZoneMemento?> load();
  Future<void> save(ZoneMemento? memento);
}

class MemoryZoneMementoStore implements ZoneMementoStore {
  ZoneMemento? memento;
  int saves = 0;

  @override
  Future<ZoneMemento?> load() async => memento;

  @override
  Future<void> save(ZoneMemento? m) async {
    memento = m;
    saves += 1;
  }
}

/// `files/state/zone.json`, tmp → flush → rename; null deletes it.
class FileZoneMementoStore implements ZoneMementoStore {
  FileZoneMementoStore(this.stateDir);
  final Directory stateDir;
  File get _file => File('${stateDir.path}/zone.json');

  @override
  Future<ZoneMemento?> load() async {
    try {
      if (!await _file.exists()) return null;
      return ZoneMemento.fromJson(jsonDecode(await _file.readAsString()));
    } catch (e) {
      debugPrint('zone memento: unreadable ($e)');
      return null;
    }
  }

  @override
  Future<void> save(ZoneMemento? m) async {
    try {
      if (m == null) {
        if (await _file.exists()) await _file.delete();
        return;
      }
      await stateDir.create(recursive: true);
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(jsonEncode(m.toJson()), flush: true);
      await tmp.rename(_file.path);
    } catch (e) {
      debugPrint('zone memento: write failed ($e)');
    }
  }
}
