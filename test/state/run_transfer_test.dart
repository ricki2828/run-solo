import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/transfer_gateway.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/run_transfer.dart';

import '../run_fixtures.dart';

/// "Move all runs (one file)": export streams to one gzipped file, import
/// reads it (and the old per-run files) back in batches.
void main() {
  final d1 = DateTime.utc(2026, 9, 10, 6);
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('rs-transfer-test-'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  List<engine.RunFile> runs(int n) => [
    for (var i = 1; i <= n; i++)
      fourByFourFile(
        n: i,
        start: d1.add(Duration(days: i)),
      ),
  ];

  test('file name and subject', () {
    expect(
      exportFileName(DateTime(2026, 10, 10, 9), 143),
      'run-supreme-runs-2026-10-10-143runs.runsupreme',
    );
    expect(exportSubject(143), 'Run Supreme: 143 runs');
    expect(exportSubject(1), 'Run Supreme: 1 run');
  });

  test('export then import on another phone: one file, all runs', () async {
    final source = MemoryRunStore(files: runs(12));
    await source.list(); // freezes verdicts into sidecars
    final gateway = FakeTransferGateway();
    final out = await RunTransfer(
      history: source,
      transfer: gateway,
      now: () => DateTime(2026, 10, 10, 9),
      tempDir: () async => dir,
    ).exportAll();
    expect(out!.runs, 12);
    expect(gateway.shared.single, [
      '${dir.path}/run-supreme-runs-2026-10-10-12runs.runsupreme',
    ]);
    final bytes = File(gateway.shared.single.single).readAsBytesSync();
    expect(bytes.take(2), [0x1f, 0x8b], reason: 'gzipped');

    final target = MemoryRunStore();
    final result = await RunTransfer(
      history: target,
      transfer: gateway,
    ).importPicked([PickedSource.fromBytes('x.runsupreme', bytes)]);
    expect(result.summary, 'Imported 12 · 0 already here');
    final listed = await target.list();
    expect(listed, hasLength(12));
    final d = await target.load(listed.first.id);
    expect(d!.analysis.verdictSource, engine.VerdictSource.frozen);

    // Again: nothing new.
    final again = await RunTransfer(
      history: target,
      transfer: gateway,
    ).importPicked([PickedSource.fromBytes('x.runsupreme', bytes)]);
    expect(again.summary, 'Imported 0 · 12 already here');
  });

  test('nothing to move shares nothing', () async {
    final gateway = FakeTransferGateway();
    final out = await RunTransfer(
      history: MemoryRunStore(),
      transfer: gateway,
      tempDir: () async => dir,
    ).exportAll();
    expect(out, isNull);
    expect(gateway.shared, isEmpty);
  });

  test(
    'import takes old per-run files, plain exports, and junk together',
    () async {
      final rs = runs(3);
      String bundle(engine.RunFile f) =>
          engine.RunBundleCodec.encode(engine.RunBundle(run: f));
      final plainExport = (await engine.RunExportCodec.encode(
        Stream.value(engine.RunBundle(run: rs[2])),
        exportedAt: d1,
      ).toList()).join();
      final target = MemoryRunStore(files: [rs[0]]);
      final result =
          await RunTransfer(
            history: target,
            transfer: FakeTransferGateway(),
          ).importPicked([
            PickedSource.fromText('a.json', bundle(rs[0])),
            PickedSource.fromText('b.json', bundle(rs[1])),
            PickedSource.fromText('all.runsupreme', plainExport),
            PickedSource.fromText('junk.json', '{"hello": 1}'),
            PickedSource.fromBytes('bad.runsupreme', [0x1f, 0x8b, 1, 2, 3]),
          ]);
      expect(result.imported, 2);
      expect(result.alreadyHere, 1);
      expect(result.unreadableFiles, 2);
      expect(
        result.summary,
        'Imported 2 · 1 already here · 2 not Run Supreme files',
      );
      expect(await target.list(), hasLength(3));
    },
  );

  test('a newer export is refused with a clear line', () async {
    final text = (await engine.RunExportCodec.encode(
      Stream.value(engine.RunBundle(run: runs(1).single)),
      exportedAt: d1,
    ).toList()).join().replaceFirst('"version":1', '"version":9');
    final target = MemoryRunStore();
    final result = await RunTransfer(
      history: target,
      transfer: FakeTransferGateway(),
    ).importPicked([PickedSource.fromText('n.runsupreme', text)]);
    expect(result.imported, 0);
    expect(result.newerFiles, 1);
    expect(result.summary, contains('newer Run Supreme'));
  });

  test('500 runs import in batches', () async {
    final base = fourByFourFile(n: 1, start: d1);
    final lines = StringBuffer();
    final bundles = [
      for (var i = 0; i < 500; i++)
        engine.RunBundle(
          run: engine.RunFile.fromJson(base.toJson()..['id'] = 'run-$i'),
        ),
    ];
    await for (final c in engine.RunExportCodec.encode(
      Stream.fromIterable(bundles),
      exportedAt: d1,
    )) {
      lines.write(c);
    }
    final target = MemoryRunStore();
    final result =
        await RunTransfer(
          history: target,
          transfer: FakeTransferGateway(),
        ).importPicked([
          PickedSource.fromBytes(
            'big.runsupreme',
            gzip.encode(utf8.encode(lines.toString())),
          ),
        ]);
    expect(result.summary, 'Imported 500 · 0 already here');
  });

  test(
    'file store: export stream carries sidecars, import restores them',
    () async {
      final tmp = await Directory.systemTemp.createTemp('rs-file-store-');
      addTearDown(() => tmp.delete(recursive: true));
      final src = FileRunStore(Directory('${tmp.path}/a/runs'));
      await src.importBundles([
        for (var i = 1; i <= 3; i++)
          engine.RunBundle(
            run: fourByFourFile(
              n: i,
              start: d1.add(Duration(days: i)),
            ),
          ),
      ]);
      await src.list(); // freezes verdicts into sidecars
      final gateway = FakeTransferGateway();
      final out = await RunTransfer(
        history: src,
        transfer: gateway,
        tempDir: () async => Directory('${tmp.path}/out')..createSync(),
      ).exportAll();
      expect(out!.runs, 3);

      final dst = FileRunStore(Directory('${tmp.path}/b/runs'));
      final bytes = File(out.path!).readAsBytesSync();
      final r = await RunTransfer(
        history: dst,
        transfer: gateway,
      ).importPicked([PickedSource.fromBytes('f.runsupreme', bytes)]);
      expect(r.summary, 'Imported 3 · 0 already here');
      final listed = await dst.list();
      expect(listed, hasLength(3));
      expect(
        (await dst.load(listed.first.id))!.analysis.verdictSource,
        engine.VerdictSource.frozen,
      );
    },
  );
}
