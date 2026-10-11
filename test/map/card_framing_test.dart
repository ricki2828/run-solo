import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/map/card_framing.dart';

void main() {
  test('padding is 22% of the card short side', () {
    expect(cardPadding(const Size(360, 148)), closeTo(32.56, 0.01));
    expect(cardPadding(const Size(100, 300)), closeTo(22, 0.01));
  });

  test('unknown size falls back to the Home card height', () {
    expect(cardPadding(null), closeTo(32.56, 0.01));
    expect(cardPadding(Size.zero), closeTo(32.56, 0.01));
  });

  test('zoom ceiling keeps a short loop from filling the card', () {
    expect(kCardMaxZoom, inInclusiveRange(14, 15));
  });
}
