import 'dart:async';

import 'package:run_solo/state/history_store.dart';

/// Runs before every test file. Phase 4 derived data (LB2) is built by a
/// background batch that `list()` never waits for; in tests it would still
/// be writing index.json when tearDown deletes the temp directory ("Directory
/// not empty"). So stores in tests build nothing by default; the index
/// tests opt in with `FileRunStore.deriveInIsolate` and await `derivedIdle`.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  FileRunStore.defaultDeriveBatch = (_) async => const {};
  await testMain();
}
