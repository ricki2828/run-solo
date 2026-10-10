// Convert RunBundle exports into the JSON the app uploads to the companion.
//
//   dart run tool/companion_facts.dart <export_dir> <out_dir> [--max-hr N] [--age N] [--rest-hr N]
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

Future<void> main(List<String> args) async {
  final pos = <String>[];
  for (var i = 0; i < args.length; i++) {
    if (args[i].startsWith('--')) {
      if (args[i] != '--generic-names') i++;
    } else {
      pos.add(args[i]);
    }
  }
  if (pos.length != 2) {
    stderr.writeln(
      'usage: companion_facts.dart <export_dir> <out_dir> [--max-hr N] [--age N] [--rest-hr N]',
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
  final opts = CompanionFactsOptions(
    maxHr: _opt(args, '--max-hr'),
    age: _opt(args, '--age'),
    restingHr: _opt(args, '--rest-hr'),
  );
  final facts = companionFactsFor(byId.values.toList(), options: opts);
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
