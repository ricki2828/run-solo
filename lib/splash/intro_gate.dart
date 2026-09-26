/// Which Lap Draw intro a cold start gets (plan §4, D8; brief A9). Read once
/// in `main()` before `runApp`, so the decision exists before the first
/// intro frame.
library;

import 'dart:async';

import '../app/services.dart';
import '../app/version.dart';
import '../platform/gateway.dart';

enum IntroKind {
  /// A run is live or a recovery journal is waiting: straight to the app.
  none,

  /// Every other cold start: 0.6 s, the R and its own line, no wordmark.
  short,

  /// First launch and the first launch of each new version: ≤ 1.5 s.
  full,
}

abstract final class IntroGate {
  /// The rule, kept pure for tests.
  ///
  /// The recording notification only exists while a run is live (recording
  /// or paused), so a launch from it is covered by [recordingLive].
  static IntroKind decide({
    required bool recordingLive,
    required bool hasRecoveryJournal,
    required String? seenVersion,
    String currentVersion = kAppVersion,
  }) {
    if (recordingLive || hasRecoveryJournal) return IntroKind.none;
    return seenVersion == currentVersion ? IntroKind.short : IntroKind.full;
  }

  /// Asks the recorder. `status()` and `recover()` run concurrently under
  /// one [timeout] budget, so a stuck platform holds the system splash for
  /// [timeout] at most. Start-up must not hang on the intro: a slow or
  /// failing call means no intro rather than a guess.
  static Future<IntroKind> read(
    AppServices services, {
    Duration timeout = const Duration(milliseconds: 400),
  }) async {
    try {
      final (status, orphans) = await (
        services.recorder.status(),
        services.recorder.recover(),
      ).wait.timeout(timeout);
      return decide(
        recordingLive:
            status.state == RecorderState.recording ||
            status.state == RecorderState.paused,
        hasRecoveryJournal: orphans.isNotEmpty,
        seenVersion: services.settings.settings.introSeenVersion,
      );
    } on Object {
      return IntroKind.none;
    }
  }
}
