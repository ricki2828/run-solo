import 'dart:convert';
import 'dart:io';

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Phase 3 plan §3.9 / §9: migrating every 4x4 to schema 3 must not change
/// one word a runner reads. `fixtures/migration/verdicts.json` was captured
/// from the schema-2 engine (4499ada) over the schema-2 inputs in
/// `fixtures/migration/schema2/` (every synthetic run + the Kotlin contract
/// files, frozen) and the schema-1 contract files; this build must give the
/// byte-identical headline, subline and HR line, with the same stage, floor
/// and band. Includes a 3-rep 4x4 (`preset_3x4_recovery_2_00`, eng-review
/// W1), staged sequences (baseline → vs last → vs median) and by-feel runs
/// overridden to a 4x4 (schema-1 `free` + override).
///
/// Regenerate ONLY on purpose: `UPDATE_MIGRATION_GOLDEN=1 dart test
/// test/migration_golden_test.dart`.
void main() {
  const hrProfile = UserProfile(maxHr: 185);
  final goldenFile = File('test/fixtures/migration/verdicts.json');

  List<(String, RunFile)> inputs() {
    final out = <(String, RunFile)>[];
    final s2 =
        Directory('test/fixtures/migration/schema2')
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.json.gz'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in s2) {
      final name = f.uri.pathSegments.last.replaceAll('.json.gz', '');
      final text = utf8.decode(gzip.decode(f.readAsBytesSync()));
      out.add(('s2/$name', RunFileCodec.decode(text)));
    }
    final s1 =
        Directory('test/fixtures/contract/schema1')
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in s1) {
      final name = f.uri.pathSegments.last.replaceAll('.json', '');
      out.add(('s1/$name', RunFileCodec.decode(f.readAsStringSync())));
    }
    return out;
  }

  // Written as the schema-2 wire value so this file compiles before and
  // after the RunMode rename; the codec maps it forward.
  RunSidecar overrideToFourByFour(String id) => RunSidecarCodec.decode(
    jsonEncode({
      'schema': 2,
      'run_id': id,
      'lap_edits': <Object?>[],
      'run_type_override': 'fourByFour',
      'notes': null,
      'frozen_verdict': null,
      'verdict_history': <Object?>[],
      'weather': null,
      'cooper': null,
    }),
  );

  Map<String, Object?>? record(Verdict? v) => v == null
      ? null
      : {
          'stage': v.stage.name,
          'headline': v.headline.text,
          'subline': v.subline,
          'hr_line': v.hrLine,
          'floor_s_per_km': v.floorSecPerKm,
          'band_s_per_km': v.bandSecPerKm,
          'delta_s_per_km': v.deltaSecPerKm,
          'rank': v.rank,
          'set_size': v.setSize,
        };

  Map<String, Object?> compute() {
    final out = <String, Object?>{};
    final all = inputs();
    for (final (name, run) in all) {
      out['single/$name'] = record(
        engine.analyze(run, profile: hrProfile, now: fixedNow).verdict,
      );
      if (run.mode == RunMode.laps) {
        out['override/$name'] = record(
          engine
              .analyze(
                run,
                sidecar: overrideToFourByFour(run.id),
                profile: hrProfile,
                now: fixedNow,
              )
              .verdict,
        );
      }
    }
    // Staged: every run in name order, each eligible 4x4 a prior for the
    // next (synthetic starts collide, so priors get one day apart).
    final priors = <PriorRun>[];
    var day = 0;
    for (final (name, run) in all) {
      final a = engine.analyze(
        run,
        priors: List.of(priors),
        profile: hrProfile,
        now: fixedNow,
      );
      out['staged/$name'] = record(a.verdict);
      final p = a.asPrior(DateTime.utc(2026, 1, 1).add(Duration(days: day++)));
      if (p != null) priors.add(p);
    }
    return out;
  }

  test('every 4x4 verdict is word-for-word what the schema-2 engine gave', () {
    final now = compute();
    if (Platform.environment['UPDATE_MIGRATION_GOLDEN'] == '1') {
      goldenFile.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(now)}\n',
      );
    }
    final golden =
        jsonDecode(goldenFile.readAsStringSync()) as Map<String, Object?>;
    expect(now.keys.toSet(), golden.keys.toSet());
    for (final k in golden.keys) {
      expect(
        jsonEncode(now[k]),
        jsonEncode(golden[k]),
        reason: '$k changed on migration',
      );
    }
    // The golden must actually cover what the plan names.
    expect(golden['single/s2/preset_3x4_recovery_2_00'], isNotNull);
    expect(
      golden.entries
          .where((e) => e.key.startsWith('staged/') && e.value != null)
          .map((e) => (e.value as Map)['stage'])
          .toSet(),
      containsAll(['baseline', 'vsLast', 'vsMedian']),
    );
    expect(
      golden.entries.where(
        (e) => e.key.startsWith('override/s1/') && e.value != null,
      ),
      isNotEmpty,
      reason: 'a schema-1 by-feel run overridden to a 4x4 has a verdict',
    );
  });
}
