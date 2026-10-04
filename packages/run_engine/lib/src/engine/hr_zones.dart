/// The five heart-rate zones as bpm boundaries. Three ways to build them:
/// share of max HR (the default), heart-rate reserve (Karvonen) and custom.
/// Pure Dart; everything that buckets HR into zones 1-5 takes one of these.
///
/// The engine's 85-95 % "in the 4x4 band" window and the interval / True
/// Pace maths are a different concept and do not read this.
library;

enum HrZoneMethod { percentMax, reserve, custom }

class HrZones {
  const HrZones._(this.method, this.z1Floor, this._bounds);

  /// Today's behaviour: Z1 < 60 %, Z2 60-70, Z3 70-80, Z4 80-90, Z5 >= 90 %
  /// of [max]. Bounds stay fractional so bucketing equals the old
  /// `max * 0.6` comparisons exactly. Not range-validated: it must keep
  /// working for any max the app resolves.
  factory HrZones.percentMax(num max) => HrZones._(
    HrZoneMethod.percentMax,
    max * 0.5,
    [max * 0.60, max * 0.70, max * 0.80, max * 0.90],
  );

  /// Heart-rate reserve (Karvonen): zone bottom = `round(rest + p * (max -
  /// rest))` for p = 40 % (Z1 floor) and 60/70/80/90 % (Z2..Z5). Plain
  /// maths: Whoop's published zones for rest 54 / max 188 (108, 136, 149,
  /// 162, 176) differ from it by up to about 2 bpm (its internal rounding
  /// is unknown); pick Custom to match them exactly. Throws if [rest] is
  /// not below [max].
  factory HrZones.reserve(int rest, int max) {
    if (rest >= max) {
      throw ArgumentError('resting HR $rest must be below max HR $max');
    }
    final hrr = (max - rest).toDouble();
    int at(double p) => (rest + p * hrr).round();
    return HrZones._(HrZoneMethod.reserve, at(0.4), [
      at(0.60),
      at(0.70),
      at(0.80),
      at(0.90),
    ]);
  }

  /// Z2..Z5 lower bounds in bpm; optional [z1Floor] is display only (the
  /// bottom of Z1, below which HR is still Z1). Throws [ArgumentError]
  /// when [validate] has a complaint.
  factory HrZones.custom(List<int> bounds, {int? z1Floor}) {
    final err = validate(bounds, z1Floor: z1Floor);
    if (err != null) throw ArgumentError(err);
    return HrZones._(HrZoneMethod.custom, z1Floor ?? bounds[0] - 1, [
      ...bounds,
    ]);
  }

  static const int minBpm = 60;
  static const int maxBpm = 230;

  /// Null when [bounds] (four Z2..Z5 bottoms) is usable: strictly ascending
  /// and within 60-230 bpm; [z1Floor], when given, must also be within
  /// 60-230 and sit below Z2.
  static String? validate(List<num> bounds, {num? z1Floor}) {
    if (bounds.length != 4) return 'Need four zone boundaries';
    for (final b in bounds) {
      if (b < minBpm || b > maxBpm) {
        return 'Zones must sit between $minBpm and $maxBpm bpm';
      }
    }
    for (var i = 1; i < bounds.length; i++) {
      if (bounds[i] <= bounds[i - 1]) {
        return 'Each zone must start higher than the one before';
      }
    }
    if (z1Floor != null) {
      if (z1Floor < minBpm || z1Floor > maxBpm) {
        return 'Zones must sit between $minBpm and $maxBpm bpm';
      }
      if (z1Floor >= bounds[0]) return 'Zone 1 must start below zone 2';
    }
    return null;
  }

  final HrZoneMethod method;

  /// Bottom of Z1 for display only; bucketing never reads it.
  final num z1Floor;

  final List<num> _bounds;

  /// Lower boundary (bpm) of zone [z] for z in 2..5.
  double lowerBound(int z) {
    if (z < 2 || z > 5) {
      throw ArgumentError.value(z, 'z', 'zones 2..5 have a lower bound');
    }
    return _bounds[z - 2].toDouble();
  }

  /// Lower bound of zone [z] in 1..5 (Z1 is [z1Floor]).
  num bottom(int z) => z == 1 ? z1Floor : _bounds[z - 2];

  /// Top of zone [z] in 1..4 as a whole bpm (the next bottom minus one);
  /// null for Z5, which has no top.
  int? top(int z) => z >= 5 ? null : (_bounds[z - 1].ceil() - 1);

  /// Zone of a raw HR with no hysteresis (1-5).
  int zoneOf(num hr) {
    for (var z = 5; z >= 2; z--) {
      if (hr >= _bounds[z - 2]) return z;
    }
    return 1;
  }

  @override
  bool operator ==(Object other) =>
      other is HrZones &&
      other.method == method &&
      other.z1Floor == z1Floor &&
      _same(other._bounds, _bounds);

  @override
  int get hashCode => Object.hash(method, z1Floor, Object.hashAll(_bounds));

  static bool _same(List<num> a, List<num> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() => 'HrZones(${method.name}, Z1 $z1Floor, $_bounds)';
}
