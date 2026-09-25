/// Moving runs between Run Solo installs (plan §4: share-sheet export, SAF
/// import, uuid dedupe). The founder's dogfood runs (`app.runsolo.dogfood`)
/// reach the Play build this way. Behind a seam so widget tests never touch
/// the share sheet or a document picker.
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart' as fs;
import 'package:share_plus/share_plus.dart' as sp;

abstract class TransferGateway {
  /// Offer [paths] (local files) through the system share sheet.
  Future<void> shareFiles(List<String> paths, {String? subject});

  /// Let the user pick one or more documents; returns their contents.
  /// Empty when cancelled.
  Future<List<PickedFile>> pickFiles();
}

class PickedFile {
  const PickedFile({required this.name, required this.text});
  final String name;
  final String text;
}

class ShareSheetTransferGateway implements TransferGateway {
  const ShareSheetTransferGateway();

  @override
  Future<void> shareFiles(List<String> paths, {String? subject}) async {
    await sp.SharePlus.instance.share(
      sp.ShareParams(
        files: [
          for (final p in paths) sp.XFile(p, mimeType: 'application/json'),
        ],
        subject: subject,
      ),
    );
  }

  @override
  Future<List<PickedFile>> pickFiles() async {
    const group = fs.XTypeGroup(
      label: 'Run Solo exports',
      extensions: ['json'],
      mimeTypes: ['application/json', 'application/octet-stream'],
    );
    final files = await fs.openFiles(acceptedTypeGroups: const [group]);
    final out = <PickedFile>[];
    for (final f in files) {
      out.add(PickedFile(name: f.name, text: await f.readAsString()));
    }
    return out;
  }
}

class FakeTransferGateway implements TransferGateway {
  FakeTransferGateway({List<PickedFile>? toPick}) : toPick = toPick ?? [];

  /// Paths handed to the share sheet, one list per call.
  final List<List<String>> shared = [];

  /// What the next [pickFiles] returns.
  final List<PickedFile> toPick;

  @override
  Future<void> shareFiles(List<String> paths, {String? subject}) async {
    // Read now: callers may delete the temp files after sharing.
    for (final p in paths) {
      if (!await File(p).exists()) throw StateError('shared file missing: $p');
    }
    shared.add(List.of(paths));
  }

  @override
  Future<List<PickedFile>> pickFiles() async => List.of(toPick);
}
