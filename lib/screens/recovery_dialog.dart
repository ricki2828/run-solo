import 'package:flutter/material.dart';

import '../app/format.dart';
import '../app/routes.dart';
import '../app/services.dart';
import '../platform/gateway.dart';
import '../theme/theme.dart';

/// Outcome of the recovery dialog.
enum RecoveryChoice { resume, finish, discard }

/// "Recovered your run from 10:47, resume or finish" (design brief §4.4).
/// Shown on app open when `recover()` returns an orphaned journal (plan
/// §3 B2: recovery happens on open only, never from the background).
///
/// Plan rule: offer Resume only when the journal is readable and under
/// 30 minutes old; older readable journals are finalised; an unreadable one
/// can only be discarded.
class RecoveryDialog extends StatelessWidget {
  const RecoveryDialog({
    super.key,
    required this.orphan,
    required this.now,
    this.remaining = 0,
  });
  final OrphanJournal orphan;
  final DateTime now;

  /// How many more orphans wait after this one ("1 of 2").
  final int remaining;

  static const Duration resumeWindow = Duration(minutes: 30);

  bool get canResume =>
      orphan.readable && orphan.lastLineAgeMs < resumeWindow.inMilliseconds;

  /// Checks for orphans and shows the dialog for the newest one. Returns true
  /// when the runner chose Resume and the record screen was pushed.
  static Future<bool> checkAndShow(BuildContext context) async {
    final services = AppServices.of(context);
    final orphans = await services.recorder.recover();
    if (orphans.isEmpty || !context.mounted) return false;
    orphans.sort((a, b) => a.lastLineAgeMs.compareTo(b.lastLineAgeMs));
    final orphan = orphans.first;
    final choice = await showDialog<RecoveryChoice>(
      context: context,
      barrierDismissible: false,
      builder: (_) => RecoveryDialog(
        orphan: orphan,
        now: DateTime.now(),
        remaining: orphans.length - 1,
      ),
    );
    if (choice == null || !context.mounted) return false;
    switch (choice) {
      case RecoveryChoice.discard:
        await services.recorder.discardJournal(orphan.runId);
        return false;
      case RecoveryChoice.finish:
        await services.recorder.finalise(orphan.runId);
        return false;
      case RecoveryChoice.resume:
        final result = await services.recorder.resumeRecovered(orphan.runId);
        if (!context.mounted) return false;
        final err = result.error;
        if (err == null || err == StartError.alreadyRunning) {
          await services.recording.attachResumed(orphan.mode);
          if (context.mounted) {
            await Navigator.of(context).pushNamed(Routes.recording);
          }
          return true;
        }
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(resumeErrorCopy(err))));
        return false;
    }
  }

  static String resumeErrorCopy(StartError e) => switch (e) {
    StartError.noSuchJournal => 'That run is gone. Nothing to resume.',
    StartError.fgsNotAllowed =>
      'Android would not restart recording. Open the app and try again.',
    StartError.noFinePermission ||
    StartError.approximateOnly ||
    StartError.locationOff => 'Precise location is needed to resume.',
    StartError.lowStorage => 'Not enough storage to resume.',
    StartError.notificationsDenied => 'Notifications are needed to resume.',
    StartError.alreadyRunning => 'A run is already recording.',
    StartError.replayUnavailable => 'Replay is not available in this build.',
    StartError.startFailed || StartError.resumeFailed =>
      'Could not resume right now. The run is kept; try again.',
  };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final lastLine = now.subtract(Duration(milliseconds: orphan.lastLineAgeMs));
    final mode = orphan.mode == RecordMode.fourByFour ? '4x4' : 'Free run';
    final counter = remaining > 0 ? ' (1 of ${remaining + 1})' : '';
    final String body;
    if (!orphan.readable) {
      body =
          'A run from ${Fmt.hhmm(lastLine)} could not be read. '
          'Nothing of it can be saved.';
    } else if (canResume) {
      body =
          '$mode, ${Fmt.clock(orphan.elapsedMs)} recorded, last written '
          '${Fmt.hhmm(lastLine)}${orphan.endedPaused ? ', paused' : ''}. '
          'Resume it or finish it as it is.';
    } else {
      body =
          '$mode, ${Fmt.clock(orphan.elapsedMs)} recorded, last written '
          '${Fmt.hhmm(lastLine)}. Too long ago to resume; it will be saved '
          'as it is.';
    }
    Widget textButton(String label, RecoveryChoice choice) => SizedBox(
      height: 56,
      child: TextButton(
        onPressed: () => Navigator.of(context).pop(choice),
        child: Text(
          label,
          style: RunSoloType.label13.copyWith(
            color: t.inkPrimary,
            fontSize: 15,
          ),
        ),
      ),
    );
    Widget filled(String label, RecoveryChoice choice) => SizedBox(
      height: 56,
      child: FilledButton(
        style: FilledButton.styleFrom(
          minimumSize: const Size(120, 56),
          textStyle: RunSoloType.title28.copyWith(fontSize: 22),
        ),
        onPressed: () => Navigator.of(context).pop(choice),
        child: Text(label),
      ),
    );
    return AlertDialog(
      backgroundColor: t.bgRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.sheet),
      ),
      title: Text(
        '${orphan.readable ? 'RECOVERED YOUR RUN' : 'UNREADABLE RUN'}$counter',
        style: RunSoloType.title28.copyWith(color: t.inkPrimary),
      ),
      content: Text(
        body,
        style: RunSoloType.body15.copyWith(color: t.inkSecondary),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(
        Space.x16,
        0,
        Space.x16,
        Space.x16,
      ),
      actions: [
        if (!orphan.readable)
          filled('DISCARD', RecoveryChoice.discard)
        else if (canResume) ...[
          textButton('FINISH', RecoveryChoice.finish),
          filled('RESUME', RecoveryChoice.resume),
        ] else
          filled('SAVE', RecoveryChoice.finish),
      ],
    );
  }
}
