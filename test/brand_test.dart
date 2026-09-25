import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Brand is RUN SUPREME (founder, 25-Sep-2026). The Dart package stays
/// `run_solo` and ids `app.runsolo*` stay; only user-visible copy changes.
void main() {
  test('no user-visible "Run Solo" copy remains in lib/', () {
    final hits = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      if (f.path.endsWith('platform_api.g.dart')) continue;
      for (final (i, line) in f.readAsLinesSync().indexed) {
        if (line.trimLeft().startsWith('//')) continue;
        if (RegExp(r"['\x22].*Run Solo.*['\x22]|RUN SOLO").hasMatch(line)) {
          hits.add('${f.path}:${i + 1}: ${line.trim()}');
        }
      }
    }
    expect(hits, isEmpty, reason: hits.join('\n'));
  });
}
