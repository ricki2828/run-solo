import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Colours live in lib/theme/*.dart only. Anywhere else, use a named token.
void main() {
  // TODO(rs-charts-sonnet): remove once the Trends and board detail rebuild
  // lands and these files use tokens.
  const allowlist = {
    'lib/screens/trend_screen.dart',
    'lib/screens/board_detail_screen.dart',
  };
  final literal = RegExp(r'Color\(\s*0x|Colors\.(?!transparent\b)[a-zA-Z]');

  test('no Color(0x...) or Colors.<name> outside lib/theme', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final path = f.path.replaceAll('\\', '/');
      if (path.startsWith('lib/theme/') || allowlist.contains(path)) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].trimLeft().startsWith('//')) continue;
        if (literal.hasMatch(lines[i])) offenders.add('$path:${i + 1}');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'use a token from lib/theme/tokens.dart',
    );
  });
}
