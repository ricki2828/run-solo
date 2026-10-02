/// Moving runs between Run Supreme installs (plan §4: share-sheet export, SAF
/// import, uuid dedupe). The founder's dogfood runs (`app.runsolo.dogfood`)
/// reach the Play build this way. Behind a seam so widget tests never touch
/// the share sheet or a document picker.
library;

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart' as fs;
import 'package:share_plus/share_plus.dart' as sp;
import 'package:url_launcher/url_launcher.dart' as ul;

abstract class TransferGateway {
  /// Offer [paths] (local files) through the system share sheet.
  /// [mimeType] defaults to the Run Supreme bundle's `application/json`.
  Future<void> shareFiles(
    List<String> paths, {
    String? subject,
    String mimeType = 'application/json',
  });

  /// Open [url] in the phone's browser. False when nothing could open it.
  Future<bool> openUrl(Uri url);

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
  Future<void> shareFiles(
    List<String> paths, {
    String? subject,
    String mimeType = 'application/json',
  }) async {
    await sp.SharePlus.instance.share(
      sp.ShareParams(
        files: [for (final p in paths) sp.XFile(p, mimeType: mimeType)],
        subject: subject,
      ),
    );
  }

  @override
  Future<bool> openUrl(Uri url) =>
      ul.launchUrl(url, mode: ul.LaunchMode.externalApplication);

  @override
  Future<List<PickedFile>> pickFiles() async {
    const group = fs.XTypeGroup(
      label: 'Run Supreme exports',
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

  final List<Completer<List<String>>> _waiting = [];

  /// Completes with the paths of the next [shareFiles] call, once its files
  /// were checked. Tests doing real file I/O await this instead of guessing
  /// a delay.
  Future<List<String>> nextShare() {
    final c = Completer<List<String>>();
    _waiting.add(c);
    return c.future;
  }

  /// Mime type of each [shareFiles] call, parallel to [shared].
  final List<String> sharedMimeTypes = [];

  /// URLs handed to the browser, in order.
  final List<Uri> opened = [];

  /// Make the next [shareFiles] throw (the share sheet could not open).
  bool failShare = false;

  @override
  Future<bool> openUrl(Uri url) async {
    opened.add(url);
    return true;
  }

  @override
  Future<void> shareFiles(
    List<String> paths, {
    String? subject,
    String mimeType = 'application/json',
  }) async {
    if (failShare) throw StateError('share sheet unavailable');
    // Read now: callers may delete the temp files after sharing.
    for (final p in paths) {
      if (!await File(p).exists()) throw StateError('shared file missing: $p');
    }
    shared.add(List.of(paths));
    sharedMimeTypes.add(mimeType);
    for (final c in _waiting) {
      c.complete(List.of(paths));
    }
    _waiting.clear();
  }

  @override
  Future<List<PickedFile>> pickFiles() async => List.of(toPick);
}
