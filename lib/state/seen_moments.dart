import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Ids of moments already shown, so none shows twice.
///
/// TODO(S4/S1): minimal stand-in. Merge with the engine stream's seen-moment
/// persistence when it lands and delete this file.
///
/// Memory first; the file is best effort (tests have no path_provider, and
/// losing it only means a moment can show once more).
class SeenMoments {
  SeenMoments._();
  static final SeenMoments instance = SeenMoments._();

  final Set<String> _ids = {};
  bool _loaded = false;

  Future<File?> _file() async {
    try {
      final dir = await getApplicationSupportDirectory();
      return File('${dir.path}/seen_moments.json');
    } on Object {
      return null;
    }
  }

  Future<Set<String>> load() async {
    if (!_loaded) {
      _loaded = true;
      try {
        final f = await _file();
        if (f != null && f.existsSync()) {
          final raw = jsonDecode(await f.readAsString());
          if (raw is List) _ids.addAll(raw.whereType<String>());
        }
      } on Object {
        // Unreadable file: start empty.
      }
    }
    return {..._ids};
  }

  Future<void> markSeen(String id) async {
    _ids.add(id);
    try {
      final f = await _file();
      await f?.writeAsString(jsonEncode(_ids.toList()), flush: true);
    } on Object {
      // Best effort.
    }
  }

  /// Test reset.
  void clearForTest() {
    _ids.clear();
    _loaded = false;
  }
}
