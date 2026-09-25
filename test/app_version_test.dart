import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/version.dart';

void main() {
  test('kAppVersion matches pubspec.yaml (the full intro keys on it)', () {
    final line = File('pubspec.yaml')
        .readAsLinesSync()
        .firstWhere((l) => l.startsWith('version:'));
    expect(kAppVersion, line.substring('version:'.length).trim());
  });
}
