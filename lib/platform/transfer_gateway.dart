/// Moving runs between Run Supreme installs (plan §4: share-sheet export, SAF
/// import, uuid dedupe). The founder's dogfood runs (`app.runsolo.dogfood`)
/// reach the Play build this way. Behind a seam so widget tests never touch
/// the share sheet or a document picker.
library;

import 'dart:async';
import 'dart:convert';
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

  /// Like [pickFiles], but hands back streams so a big export is read in
  /// chunks, never as one string. Empty when cancelled.
  Future<List<PickedSource>> pickRunSources();

  /// Let the user pick one GPX or TCX route file (Follow a route); its text,
  /// or null when cancelled. The file is read here and never copied or sent.
  Future<PickedFile?> pickRouteFile();
}

/// A route file bigger than this is refused before it is read (a day's
/// recording at 1 Hz is well under 1 MB; this is for the wrong file).
const int kMaxRouteFileBytes = 10 * 1024 * 1024;

/// Thrown by [TransferGateway.pickRouteFile] for a file over [kMaxRouteFileBytes].
class RouteFileTooBig implements Exception {
  const RouteFileTooBig();
  @override
  String toString() => 'That file is too big for a route, max 10 MB';
}

class PickedFile {
  const PickedFile({required this.name, required this.text});
  final String name;
  final String text;
}

/// A picked document that is opened (and read) only when asked.
class PickedSource {
  const PickedSource({required this.name, required this.open});
  PickedSource.fromText(String name, String text)
    : this(name: name, open: () => Stream.value(utf8.encode(text)));
  PickedSource.fromBytes(String name, List<int> bytes)
    : this(name: name, open: () => Stream.value(bytes));
  final String name;

  /// A fresh byte stream each call (the reader peeks, then reads).
  final Stream<List<int>> Function() open;
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

  @override
  Future<List<PickedSource>> pickRunSources() async {
    // Any file: Drive can hand back an export with no extension (it once
    // saved one as "Run Supreme: 7 runs"). The reader sniffs gzip and
    // reports anything that is not a Run Supreme file.
    final files = await fs.openFiles();
    return [
      for (final f in files) PickedSource(name: f.name, open: f.openRead),
    ];
  }

  @override
  Future<PickedFile?> pickRouteFile() async {
    // GPX and TCX have no registered Android type of their own: the extension
    // narrows the picker where it can, the XML types where it cannot.
    const group = fs.XTypeGroup(
      label: 'GPX or TCX route',
      extensions: ['gpx', 'tcx'],
      mimeTypes: [
        'application/gpx+xml',
        'application/vnd.garmin.tcx+xml',
        'application/xml',
        'text/xml',
        'application/octet-stream',
      ],
    );
    final f = await fs.openFile(acceptedTypeGroups: const [group]);
    if (f == null) return null;
    if (await f.length() > kMaxRouteFileBytes) throw const RouteFileTooBig();
    return PickedFile(name: f.name, text: await f.readAsString());
  }
}

class FakeTransferGateway implements TransferGateway {
  FakeTransferGateway({List<PickedFile>? toPick, List<PickedFile>? toPickRoute})
    : toPick = toPick ?? [],
      toPickRoute = toPickRoute ?? [];

  /// What the next [pickRouteFile] returns (one per call; null once empty).
  final List<PickedFile> toPickRoute;

  /// Paths handed to the share sheet, one list per call.
  final List<List<String>> shared = [];

  /// What the next [pickFiles] returns.
  final List<PickedFile> toPick;

  /// Extra picks for [pickRunSources] (e.g. gzipped bytes), after [toPick].
  final List<PickedSource> toPickSources = [];

  final List<Completer<List<String>>> _waiting = [];

  /// Completes with the paths of the next [shareFiles] call, once its files
  /// were checked. Tests doing real file I/O await this instead of guessing
  /// a delay.
  Future<List<String>> nextShare() {
    final c = Completer<List<String>>();
    _waiting.add(c);
    return c.future;
  }

  /// Bytes of the first file of each [shareFiles] call, read at share time
  /// (callers delete the temp file afterwards).
  final List<List<int>> sharedBytes = [];

  /// Subject of each [shareFiles] call, parallel to [shared].
  final List<String?> sharedSubjects = [];

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
    sharedSubjects.add(subject);
    sharedBytes.add(
      paths.isEmpty ? <int>[] : await File(paths.first).readAsBytes(),
    );
    sharedMimeTypes.add(mimeType);
    for (final c in _waiting) {
      c.complete(List.of(paths));
    }
    _waiting.clear();
  }

  @override
  Future<List<PickedFile>> pickFiles() async => List.of(toPick);

  @override
  Future<List<PickedSource>> pickRunSources() async => [
    for (final f in toPick) PickedSource.fromText(f.name, f.text),
    ...toPickSources,
  ];

  @override
  Future<PickedFile?> pickRouteFile() async {
    if (toPickRoute.isEmpty) return null;
    final f = toPickRoute.removeAt(0);
    if (f.text.length > kMaxRouteFileBytes) throw const RouteFileTooBig();
    return f;
  }
}
