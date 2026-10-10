import 'dart:convert';
import 'dart:io';

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// "Move all runs (one file)": the single-document export.
void main() {
  final base = fixture('four_by_four_manual_clean_hr').run;
  final lapsRun = fixture('laps_run_manual_clean_hr').run;
  final at = DateTime.utc(2026, 10, 10, 8);

  RunBundle clone(RunFile src, int n, {bool sidecar = false}) {
    final j = src.toJson()..['id'] = 'run-$n';
    final run = RunFile.fromJson(j);
    return RunBundle(
      run: run,
      sidecar: sidecar ? RunSidecar(runId: run.id, notes: 'n$n') : null,
    );
  }

  Future<String> exportText(List<RunBundle> bs) async =>
      (await RunExportCodec.encode(
        Stream.fromIterable(bs),
        exportedAt: at,
      ).toList()).join();

  Stream<String> linesOf(String text) =>
      Stream.value(text).transform(const LineSplitter());

  Future<List<RunBundle>> readAll(String text, {List<Object>? skipped}) =>
      RunExportCodec.readAny(linesOf(text), onSkipped: skipped?.add).toList();

  test('round trip keeps every run, sidecar and edit', () async {
    final a = clone(base, 1, sidecar: true);
    final b = clone(lapsRun, 2);
    final text = await exportText([a, b]);

    final j = jsonDecode(text) as Map<String, Object?>;
    expect(j['format'], 'runsupreme-export');
    expect(j['version'], 1);
    expect(j['exported_at'], '2026-10-10T08:00:00.000Z');
    expect((j['runs'] as List), hasLength(2));

    final streamed = await readAll(text);
    final whole = RunExportCodec.decode(text);
    for (final back in [streamed, whole]) {
      expect(back.map((x) => x.id), ['run-1', 'run-2']);
      expect(back[0].sidecar!.notes, 'n1');
      expect(back[1].sidecar, isNull);
      expect(RunBundleCodec.encode(back[0]), RunBundleCodec.encode(a));
      expect(RunBundleCodec.encode(back[1]), RunBundleCodec.encode(b));
    }
  });

  test('an empty export is valid and reads as no runs', () async {
    final text = await exportText([]);
    expect(jsonDecode(text), isA<Map>());
    expect(await readAll(text), isEmpty);
  });

  test('old per-run files still read (bundle and bare run)', () async {
    final bundle = RunBundleCodec.encode(clone(base, 1, sidecar: true));
    expect((await readAll(bundle)).single.sidecar!.notes, 'n1');
    final bare = RunFileCodec.encode(lapsRun);
    expect((await readAll(bare)).single.id, lapsRun.id);
    final pretty = const JsonEncoder.withIndent(' ')
        .convert(jsonDecode(bundle));
    expect((await readAll(pretty)).single.id, 'run-1');
  });

  test('large export: 500 runs round trip', () async {
    final bundles = [for (var i = 0; i < 500; i++) clone(base, i)];
    final text = await exportText(bundles);
    final back = await readAll(text);
    expect(back, hasLength(500));
    expect(back.map((x) => x.id).toSet(), hasLength(500));
    expect(back.last.id, 'run-499');
  });

  test('corrupt file: not JSON, empty, truncated, damaged run', () async {
    await expectLater(readAll('hello'), throwsA(isA<RunFileFormatException>()));
    await expectLater(readAll(''), throwsA(isA<RunFileFormatException>()));
    expect(
      () => RunExportCodec.decode('{nope'),
      throwsA(isA<RunFileFormatException>()),
    );

    final text = await exportText([clone(base, 1), clone(base, 2)]);
    // Cut short: the intact runs still come through, then it throws.
    final cut = text.substring(0, text.lastIndexOf('\n]}'));
    final got = <String>[];
    await expectLater(
      RunExportCodec.readAny(linesOf(cut)).forEach((b) => got.add(b.id)),
      throwsA(isA<RunFileFormatException>()),
    );
    expect(got, ['run-1', 'run-2']);

    // One damaged line is skipped and reported; neighbours survive.
    final lines = text.split('\n');
    lines[2] = '{"kind":"runsolo-export","schema":1,"run":{}}';
    final skipped = <Object>[];
    final back = await readAll(lines.join('\n'), skipped: skipped);
    expect(back.map((x) => x.id), ['run-1']);
    expect(skipped, hasLength(1));
  });

  test('a newer-version file is refused, not misread', () async {
    final text = (await exportText([clone(base, 1)]))
        .replaceFirst('"version":1', '"version":2');
    await expectLater(
      readAll(text),
      throwsA(isA<RunFileNewerVersionException>()),
    );
    expect(
      () => RunExportCodec.decode(text),
      throwsA(isA<RunFileNewerVersionException>()),
    );
  });

  test('a run from a newer app inside an export is skipped', () async {
    final text = await exportText([clone(base, 1), clone(base, 2)]);
    final lines = text.split('\n');
    lines[1] = lines[1].replaceFirst(
      '"schema":${RunFile.schema}',
      '"schema":${RunFile.schema + 1}',
    );
    final skipped = <Object>[];
    final back = await readAll(lines.join('\n'), skipped: skipped);
    expect(back.map((x) => x.id), ['run-2']);
    expect(skipped.single, isA<RunFileNewerVersionException>());
  });

  test('memory: the writer streams to gzip, never holding the export', () async {
    // 800 runs generated lazily and piped through gzip to disk. The whole
    // text never exists in one piece, so resident-set growth stays far below
    // the document size.
    const runs = 800;
    final one = RunBundleCodec.encode(clone(base, 0, sidecar: true)).length;
    Stream<RunBundle> gen() async* {
      for (var i = 0; i < runs; i++) {
        yield clone(base, i, sidecar: true);
      }
    }

    final dir = Directory.systemTemp.createTempSync('rs-export-mem-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}/x.runsupreme');
    final before = ProcessInfo.currentRss;
    var peak = before;
    final ticker = Stream.periodic(const Duration(milliseconds: 10), (_) {
      final r = ProcessInfo.currentRss;
      if (r > peak) peak = r;
    }).listen((_) {});
    await RunExportCodec.encode(
      gen(),
      exportedAt: at,
    ).transform(utf8.encoder).transform(gzip.encoder).pipe(f.openWrite());
    await ticker.cancel();
    final grew = peak - before;
    final plain = one * runs;
    // ignore: avoid_print
    print(
      'export mem: ${plain ~/ 1024} KB of JSON, file ${f.lengthSync() ~/ 1024} '
      'KB, RSS grew ${grew ~/ 1024} KB',
    );
    // Growth plateaus (~30 MB) while the document is ~95 MB.
    expect(grew, lessThan(plain ~/ 2));

    var n = 0;
    await RunExportCodec.readAny(
      f
          .openRead()
          .transform(gzip.decoder)
          .transform(utf8.decoder)
          .transform(const LineSplitter()),
    ).forEach((_) => n++);
    expect(n, runs);
  });
}
