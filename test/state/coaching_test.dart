import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_engine/testing.dart' as synth;
import 'package:run_solo/state/history_store.dart';

import '../run_fixtures.dart';

/// CR2: after-run coaching and Home's "try next" from the index entries
/// (W5b: a device's summaries carry no analysis), on the file store.
void main() {
  final d1 = DateTime.utc(2026, 8, 1, 6);
  DateTime day(int n) => d1.add(Duration(days: n));

  late Directory dir;
  final stores = <FileRunStore>[];
  setUp(() async => dir = await Directory.systemTemp.createTemp('cr2-'));
  tearDown(() async {
    for (final s in stores) {
      await s.derivedIdle;
    }
    stores.clear();
    await dir.delete(recursive: true);
  });

  /// A 10.2 km free run: 5.1 km at [first] s/km, then 5.1 km at
  /// [second] (a little over 10 km so the 10K board window fits).
  engine.RunFile tenK(int n, DateTime start, int first, int second) => generator
      .generate(
        synth.SyntheticSpec(
          name: 'cr2_$n',
          id: runId(n),
          mode: engine.RunMode.free,
          lapStyle: synth.LapStyle.none,
          start: start,
          segments: [
            synth.Segment.free(first * 51 ~/ 10, speedFor(first)),
            synth.Segment.free(second * 51 ~/ 10, speedFor(second)),
          ],
        ),
      )
      .run;

  Future<FileRunStore> store(List<engine.RunFile> files) async {
    final s = FileRunStore(Directory('${dir.path}/runs'));
    s.deriveBatch = FileRunStore.deriveInIsolate;
    stores.add(s);
    await s.importBundles([for (final f in files) engine.RunBundle(run: f)]);
    await s.list();
    await s.derivedIdle;
    return s;
  }

  // Three 10Ks, each slowing about 10% in the second half; none of them
  // an hour long.
  List<engine.RunFile> fading() => [
    tenK(1, day(0), 300, 330),
    tenK(2, day(3), 300, 330),
    tenK(3, day(6), 300, 332),
  ];

  test('the last of three fading 10Ks: the research-based fade line and the '
      'Zone 2 suggestion, from index entries', () async {
    final runs = fading();
    final c = await (await store(runs)).coaching();
    final report = c.reportFor(runs.last.id)!;
    expect(report.observation!.researchBased, isTrue);
    expect(report.observation!.text, contains('research-based'));
    expect(report.suggestion!.kind, engine.SuggestionKind.zone2LongRun);
    final next = c.tryNext()!;
    expect(next.runId, runs.last.id);
    expect(next.reason, contains('no run of an hour or more'));
    expect(c.tryNext(dismissedRunId: runs.last.id), isNull, reason: 'x');
    expect(
      c.reportFor(runs.first.id)!.suggestion,
      isNull,
      reason: 'never off a single run',
    );
  });

  test('the card goes once the suggested session type is run: a 65 min '
      'easy run', () async {
    final long = generator
        .generate(
          synth.SyntheticSpec(
            name: 'cr2_long',
            id: runId(9),
            mode: engine.RunMode.free,
            lapStyle: synth.LapStyle.none,
            start: day(8),
            segments: [synth.Segment.free(65 * 60, speedFor(420))],
          ),
        )
        .run;
    final c = await (await store([...fading(), long])).coaching();
    expect(c.tryNext(), isNull);
  });

  test('a run with no derived data yet has no coaching (no heading)', () async {
    final s = FileRunStore(Directory('${dir.path}/runs'));
    stores.add(s); // default batch: builds no derived data
    await s.importBundles([for (final f in fading()) engine.RunBundle(run: f)]);
    await s.list();
    final c = await s.coaching();
    expect(c.reportFor(runId(3)), isNull);
    expect(c.tryNext(), isNull);
  });
}
