import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

/// WARN-4 string lint for the Cooper surfaces (CO1, HV1): every string that
/// carries a research-derived number reads as an estimate, as rendered.
void main() {
  test('Cooper projection cue, range line and heat strings are labelled', () {
    final strings = <String>[];
    for (final metres in [1800.0, 2741.0, 3600.0]) {
      final e = CooperEstimate(metres);
      strings
        ..add(e.rangeLine)
        ..addAll([for (var m = 2; m <= 11; m++) e.cue(m)]);
    }
    final heat = CooperHeat.adjust(
      tempC: 22,
      dewPointC: 14,
      shortwaveWm2: 800,
      windMs: 1,
    );
    strings
      ..add(heat.line(52.8)!)
      ..add(CooperHeat.disclosure)
      ..add(CooperHeat.caveat);
    for (final s in strings) {
      expect(carriesEstimateMarker(s), isTrue, reason: s);
      expect(s.contains('—'), isFalse, reason: 'no em dashes: $s');
    }
  });

  test('the bare range needs its label: without it the lint fails', () {
    expect(
      carriesEstimateMarker(const CooperEstimate(2800).rangeText),
      isFalse,
    );
    expect(CooperEstimate.rangeLabel, contains('estimate'));
  });
}
