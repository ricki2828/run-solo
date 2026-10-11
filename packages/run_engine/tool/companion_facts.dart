// Convert RunBundle exports into the JSON the app uploads to the companion.
//
//   dart run tool/companion_facts.dart <export_dir> <out_dir> [--max-hr N] [--age N] [--rest-hr N] [--no-route] [--zones FILE]
//
// Reads every `*.json` in <export_dir> (`run-<id>.runsupreme.json`), writes
// `<out_dir>/NNNN-<run id>.json` sorted by start time. See
// companion_facts_lib.dart for what cannot be derived.
// ignore: unnecessary_library_name
library;

import 'dart:convert';
import 'dart:io';

import 'package:run_engine/run_engine.dart';

import 'companion_facts_lib.dart';

int? _opt(List<String> args, String name) {
  final i = args.indexOf(name);
  if (i < 0 || i + 1 >= args.length) return null;
  return int.tryParse(args[i + 1]);
}

String? _str(List<String> args, String name) {
  final i = args.indexOf(name);
  return i < 0 || i + 1 >= args.length ? null : args[i + 1];
}

/// `--zones FILE`, else one stable file per facts folder under
/// `~/.config/run-supreme/privacy-zones/`.
String _zonesPath(List<String> args, String outDir) {
  final given = _str(args, '--zones');
  if (given != null) return given;
  final home = Platform.environment['HOME'] ?? '.';
  final abs = Directory(outDir).absolute.path;
  return '$home/.config/run-supreme/privacy-zones/${Uri.encodeComponent(abs)}.json';
}

List<PrivacyZone> _readZones(String path) {
  final f = File(path);
  if (!f.existsSync()) return const [];
  try {
    final j = jsonDecode(f.readAsStringSync());
    if (j is! List) return const [];
    return [for (final z in j) ?PrivacyZone.fromJson(z)];
  } on FormatException {
    return const [];
  }
}

void _writeZones(String path, List<PrivacyZone> zones) {
  final f = File(path);
  f.parent.createSync(recursive: true);
  if (!Platform.isWindows) Process.runSync('chmod', ['700', f.parent.path]);
  f.writeAsStringSync(jsonEncode([for (final z in zones) z.toJson()]));
  if (!Platform.isWindows) Process.runSync('chmod', ['600', path]);
  stdout.writeln(
    'privacy zones kept in $path (secret: do not share or commit)',
  );
}

Future<void> main(List<String> args) async {
  final pos = <String>[];
  for (var i = 0; i < args.length; i++) {
    if (args[i].startsWith('--')) {
      if (args[i] != '--generic-names' && args[i] != '--no-route') i++;
    } else {
      pos.add(args[i]);
    }
  }
  if (pos.length != 2) {
    stderr.writeln(
      'usage: companion_facts.dart <export_dir> <out_dir> [--max-hr N] [--age N] [--rest-hr N] [--no-route] [--zones FILE]',
    );
    exit(64);
  }
  final files =
      Directory(pos[0])
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final bundles = <RunBundle>[];
  for (final f in files) {
    try {
      bundles.add(RunBundleCodec.decode(f.readAsStringSync()));
    } on RunFileFormatException catch (e) {
      stderr.writeln('skipped ${f.uri.pathSegments.last}: $e');
    }
  }
  // Same run twice (export bundle plus a bare file): the copy with a sidecar wins.
  final byId = <String, RunBundle>{};
  for (final b in bundles) {
    final cur = byId[b.id];
    if (cur == null || (cur.sidecar == null && b.sidecar != null)) {
      byId[b.id] = b;
    }
  }
  // The secret privacy zones are kept in one file per facts folder, outside the
  // repo and the facts folder (the server reads every .json in that one), mode
  // 600, and reused by every replay: two replays with different circles around
  // the same door would narrow it to their overlap.
  final zonesPath = _zonesPath(args, pos[1]);
  final known = _readZones(zonesPath);
  var latest = known;
  final opts = CompanionFactsOptions(
    maxHr: _opt(args, '--max-hr'),
    age: _opt(args, '--age'),
    restingHr: _opt(args, '--rest-hr'),
    withRoute: !args.contains('--no-route'),
    privacyZones: known,
    onZones: (z) => latest = z,
  );
  final facts = companionFactsFor(byId.values.toList(), options: opts);
  if (latest.length != known.length) _writeZones(zonesPath, latest);
  Directory(pos[1]).createSync(recursive: true);
  var n = 0;
  var held = 0;
  for (final f in facts) {
    if (f == null) {
      held++;
      continue;
    }
    n++;
    final name = '${n.toString().padLeft(4, '0')}-${f['run_id']}.json';
    File('${pos[1]}/$name')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(f));
  }
  stdout.writeln(
    'wrote $n run files to ${pos[1]}; $held held back (no time zone, the app would wait too)',
  );
  stdout.writeln(
    'not derivable, absent from every file: ${kNotSentByTheApp.join(', ')}',
  );
}
