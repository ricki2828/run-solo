import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/state/run_index.dart';
import 'package:run_solo/state/zone_histogram.dart';

import '../run_fixtures.dart';

/// Zone charts: the index keeps moving seconds per bpm, zones are worked out
/// at view time.
void main() {
  final start = DateTime.utc(2026, 10, 5, 6);
  final zones = engine.HrZones.percentMax(190);

  engine.RunFile runWith(int? Function(int sec) hrAt) {
    final base = freeRunFile(n: 1, start: start, seconds: 600);
    return base.copyWith(
      samples: [
        for (final s in base.samples) s.copyWith(hr: hrAt(s.tMs ~/ 1000)),
      ],
    );
  }

  test('HrHist: zones come from the current method, no re-index', () {
    final run = runWith((s) => s < 200 ? 120 : 160);
    final h = HrHist.of(run)!;
    final pct = h.zoneSeconds(zones);
    expect(pct[2], greaterThan(150));
    expect(pct[4], greaterThan(300));
    // Same histogram, a lower max: the same bpm lands in higher zones.
    final low = h.zoneSeconds(engine.HrZones.percentMax(150));
    expect(low[5], greaterThan(300));
  });

  test('HrHist survives the JSON round trip; none without a strap', () {
    final h = HrHist.of(runWith((s) => 130))!;
    final back = HrHist.fromJson(h.toJson())!;
    expect(back.minBpm, h.minBpm);
    expect(back.secs, h.secs);
    expect(HrHist.of(runWith((s) => null)), isNull);
    expect(HrHist.fromJson(null), isNull);
  });

  test('dominantZoneOf: by time in the window; null without HR', () {
    final run = runWith((s) => s < 100 ? 120 : 160);
    expect(dominantZoneOf(run, zones, (s) => s.tMs < 90000), 2);
    expect(dominantZoneOf(run, zones, (s) => s.tMs >= 200000), 4);
    expect(dominantZoneOf(runWith((s) => null), zones, (s) => true), isNull);
  });

  test('IndexRow carries hrHist at version 15', () {
    expect(IndexRow.currentVersion, 15);
  });
}
