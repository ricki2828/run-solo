import 'dart:convert';
import 'dart:io';

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

GhostTrail _trail(Map<String, dynamic> j) {
  GhostProfile prof(Map<String, dynamic> p) => GhostProfile(
    runId: p['runId'] as String,
    dateMs: p['dateMs'] as int,
    ms: [for (final v in p['ms'] as List) (v as num).toInt()],
  );
  return GhostTrail(
    id: j['id'] as String,
    name: j['name'] as String,
    latLon: [for (final v in j['ll'] as List) (v as num).toDouble()],
    best: prof(j['best'] as Map<String, dynamic>),
    last: j['last'] == null ? null : prof(j['last'] as Map<String, dynamic>),
    turnAlongM: (j['turnM'] as num?)?.toDouble(),
  );
}

/// The shared Dart/Kotlin vectors (core-jvm TrailGhostParityTest replays the
/// same file): every field of every state. Regenerate only with
/// `dart run tool/gen_trail_ghost_vectors.dart` after a deliberate change to
/// both trackers.
void main() {
  test('the tracker reproduces every state in the shared vectors', () {
    final doc = jsonDecode(
      File('test/fixtures/trail_ghost/vectors.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final vectors = (doc['vectors'] as List).cast<Map<String, dynamic>>();
    expect(vectors.length, greaterThanOrEqualTo(8));
    var matched = 0, turns = 0, never = 0, switchCount = 0;
    for (final v in vectors) {
      final name = v['name'] as String;
      final g = TrailGhostTracker([
        for (final t in v['trails'] as List) _trail(t as Map<String, dynamic>),
      ]);
      final points = v['points'] as List;
      final states = v['states'] as List;
      final events = <int>[];
      final switches = <List<Object?>>[];
      var anyState = false;
      for (var i = 0; i < points.length; i++) {
        final p = points[i] as List;
        for (final e in g.offer(
          (p[0] as num).toInt(),
          (p[1] as num).toDouble(),
          (p[2] as num).toDouble(),
          (p[3] as num).toDouble(),
          (p[4] as num).toInt(),
          (p[5] as num).toDouble(),
        )) {
          events.add(e.t);
        }
        for (final w in g.drainSwitches()) {
          switches.add([w.t, w.trailId, w.toLast]);
        }
        final want = states[i] as List;
        final s = g.state;
        final at = '$name #$i';
        if (want[0] == null) {
          expect(s, isNull, reason: at);
          continue;
        }
        anyState = true;
        expect(s, isNotNull, reason: at);
        expect(s!.trailId, want[0], reason: '$at trail');
        expect(s.alongM, closeTo((want[1] as num).toDouble(), 0.5), reason: at);
        expect(s.off, want[2], reason: '$at off');
        expect(s.aheadBestMs, want[3], reason: '$at best');
        expect(s.aheadLastMs, want[4], reason: '$at last');
        expect(s.turnCue, want[5], reason: '$at cue');
        expect(s.toTurnM, (want[6] as num?)?.toDouble(), reason: '$at toTurn');
        expect(s.racing, want[7], reason: '$at racing');
      }
      expect(events, (v['turnEvents'] as List).cast<int>(), reason: name);
      expect(switches, v['switches'], reason: '$name switches');
      switchCount += switches.length;
      if (anyState) {
        matched++;
      } else {
        never++;
      }
      turns += events.length;
    }
    // The vectors must exercise matches, no-matches and a turnaround.
    expect(matched, greaterThanOrEqualTo(6));
    expect(never, greaterThanOrEqualTo(3));
    expect(turns, greaterThanOrEqualTo(1));
    // A slip to the last run and a recovery back to the best.
    expect(switchCount, greaterThanOrEqualTo(2));
  });
}
