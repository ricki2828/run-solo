import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/recording_screen.dart';
import 'package:run_solo/widgets/delta_glyph.dart';

void main() {
  // Paces are s/km; the display unit decides the rounding (lead P3 on #27):
  // "±" only when the delta AS SHOWN is 0, never "±1 s" / "±2 s".
  const last = 285.0;

  test('0.6 s/km slower: km shows "1 s" with the slower arrow, not ±1 s', () {
    final g = ghostDelta(last + 0.6, last, Units.km);
    expect(g.text, '1 s');
    expect(g.direction, DeltaDirection.down);
  });

  test('0.6 s/km faster in miles (0.97 s/mi): "1 s" with the faster arrow', () {
    final g = ghostDelta(last - 0.6, last, Units.mi);
    expect(g.text, '1 s');
    expect(g.direction, DeltaDirection.up);
  });

  test('0.4 s/km: ±0 s in km, but 0.64 s/mi rounds to 1 s in miles', () {
    final km = ghostDelta(last + 0.4, last, Units.km);
    expect(km.text, '±0 s');
    expect(km.direction, DeltaDirection.flat);
    final mi = ghostDelta(last + 0.4, last, Units.mi);
    expect(mi.text, '1 s');
    expect(mi.direction, DeltaDirection.down);
  });

  test('identical paces: ±0 s, flat, in both units', () {
    for (final u in Units.values) {
      final g = ghostDelta(last, last, u);
      expect(g.text, '±0 s');
      expect(g.direction, DeltaDirection.flat);
    }
  });

  test('no display ever pairs ± with a non-zero number', () {
    for (var d = -3.0; d <= 3.0; d += 0.05) {
      for (final u in Units.values) {
        final g = ghostDelta(last + d, last, u);
        if (g.text.startsWith('±')) expect(g.text, '±0 s', reason: '$d $u');
      }
    }
  });
}
