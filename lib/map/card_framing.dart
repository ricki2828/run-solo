/// How a Home recent-run card frames its map: the run's bounds plus breathing
/// room, with a zoom ceiling so a short loop does not fill the card.
library;

import 'dart:math' as math;
import 'dart:ui' show Size;

/// The card's shortest side times this is the padding on every side, so the
/// route fills about half of a 148 dp tall card and the streets around it
/// show.
const double kCardPadFraction = 0.22;

/// Highest zoom a card snapshot may use (about 1.2 km across a 148 dp card
/// at 40 degrees latitude).
const double kCardMaxZoom = 14;

/// Added to the cache key so snapshots framed the old, tight way are not
/// served after this change. Bump when the framing changes again.
const String kCardFramingKey = 'fit2';

/// Padding in logical pixels for a card of [size]. Falls back to the Home
/// card's height when the size is not known yet.
double cardPadding(Size? size) {
  final side = (size == null || size.isEmpty)
      ? 148.0
      : math.min(size.width, size.height);
  return side * kCardPadFraction;
}
