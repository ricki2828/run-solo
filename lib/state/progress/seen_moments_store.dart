import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Which full-screen moments the runner has already seen, so each shows
/// once. Same pattern as `FileSettingsStore`: a small JSON file in the app's
/// state directory, written atomically (tmp + rename).
abstract class SeenMomentsStore {
  Future<Set<String>> load();

  /// Adds [ids] to the seen set and saves it.
  Future<Set<String>> markSeen(Iterable<String> ids);
}

class MemorySeenMomentsStore implements SeenMomentsStore {
  MemorySeenMomentsStore([Iterable<String> initial = const []])
    : _seen = {...initial};
  final Set<String> _seen;

  @override
  Future<Set<String>> load() async => {..._seen};

  @override
  Future<Set<String>> markSeen(Iterable<String> ids) async {
    _seen.addAll(ids);
    return {..._seen};
  }
}

/// `files/state/seen_moments.json`: `{"seen": ["first:first-run", ...]}`.
class FileSeenMomentsStore implements SeenMomentsStore {
  FileSeenMomentsStore(this.stateDir);
  final Directory stateDir;

  File get _file => File('${stateDir.path}/seen_moments.json');

  @override
  Future<Set<String>> load() async {
    try {
      if (!await _file.exists()) return {};
      final json = jsonDecode(await _file.readAsString());
      if (json is Map<String, Object?> && json['seen'] is List) {
        return {
          for (final e in json['seen']! as List<Object?>)
            if (e is String) e,
        };
      }
    } catch (e) {
      debugPrint('seen moments: unreadable, starting empty ($e)');
    }
    return {};
  }

  @override
  Future<Set<String>> markSeen(Iterable<String> ids) async {
    final seen = await load()
      ..addAll(ids);
    await stateDir.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({'seen': (seen.toList()..sort())}),
      flush: true,
    );
    await tmp.rename(_file.path);
    return seen;
  }
}
