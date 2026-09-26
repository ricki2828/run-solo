import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/event_names.dart';
import 'package:run_solo/platform/session_codec.dart';

/// Every engine field survives the trip to the recorder and back
/// (CONTRACT.md I1: the same shape). K1: `autoStop` used to be dropped, so
/// an event run started from the app never stopped itself at 5.00 km.
void main() {
  final specs = [
    for (final p in engine.SessionCatalogue.presets) p.defaults,
    engine.SessionSpec.parkrun(kEventNames.parkrun),
    engine.SessionSpec.cooper,
    engine.SessionSpec.fartlek,
  ];
  for (final s in specs) {
    test('round trip: ${s.templateId}', () {
      final back = s.toPigeon().toEngine();
      expect(back, s);
      expect(back.autoStop, s.autoStop);
    });
  }

  test('the event session reaches the recorder with autoStop on', () {
    expect(
      engine.SessionSpec.parkrun(kEventNames.parkrun).toPigeon().autoStop,
      isTrue,
    );
  });
}
