import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/identity_display.dart';

void main() {
  test('percentile display is a number, including published bounds', () {
    expect(IdentityDisplay.percentileNumber('about 45th'), '45');
    expect(IdentityDisplay.percentileNumber('above 90th'), '90');
    expect(IdentityDisplay.percentileNumber('below 10th'), '10');
    expect(IdentityDisplay.percentileNumber(null), isNull);
  });

  test('each unlocked performance lane has a distance-labelled time', () {
    for (final (lane, metres, ms, time, label) in [
      (engine.IdentityLane.speed, 1000.0, 240000, '4:00', 'Race-pace guess, 1K'),
      (engine.IdentityLane.mid, 5000.0, 1500000, '25:00', 'Race-pace guess, 5K'),
      (
        engine.IdentityLane.long,
        21097.5,
        7200000,
        '2:00:00',
        'Race-pace guess, half marathon',
      ),
    ]) {
      final score = engine.IdentityScore(
        lane: lane,
        score: 50,
        vdot: engine.FitnessHero.vdot(metres, ms),
        runId: 'test',
        date: DateTime(2026),
        source: 'test',
        boardKey: null,
      );
      expect(IdentityDisplay.equivalentTime(score), time);
      expect(IdentityDisplay.equivalentLabel(lane), label);
    }
  });
}
