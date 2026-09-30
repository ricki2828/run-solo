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
  final literal = RegExp(
    r'Color\(\s*0x|Color\.from(ARGB|RGBO)\s*\(|CupertinoColors\.|'
    r'Colors\.(?!transparent\b)[a-zA-Z]',
  );

  test('no colour literals outside lib/theme', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final path = f.path.replaceAll('\\', '/');
      if (path.startsWith('lib/theme/') || allowlist.contains(path)) continue;
      // Whole-file scan: dart format can split `Color(` and `0x...` across lines.
      final text = f.readAsStringSync().replaceAll(
        RegExp(r'//.*$', multiLine: true),
        '',
      );
      for (final m in literal.allMatches(text)) {
        final line = '\n'.allMatches(text.substring(0, m.start)).length + 1;
        offenders.add('$path:$line');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'use a token from lib/theme/tokens.dart',
    );
  });
}
