import 'dart:math' as math;

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// A lopsided closed curve about 2 km round (not a circle, so a reversed lap
/// is genuinely different), as (lat, lon) fixes [n] along it, [shift] of the
/// way round the start, with [noiseM] of GPS wobble.
List<(double, double)> loopFixes({
  int n = 400,
  double shift = 0,
  double noiseM = 0,
  double scale = 1,
  double dLat = 0,
  int seed = 1,
  bool reverse = false,
  double upTo = 1,
}) {
  final rnd = math.Random(seed);
  const lat0 = 37.4, lon0 = 24.9;
  const mPerDeg = 111194.9;
  final kx = math.cos(lat0 * math.pi / 180) * mPerDeg;
  final out = <(double, double)>[];
  for (var i = 0; i <= n; i++) {
    var f = (i / n) * upTo + shift;
    if (reverse) f = shift + upTo - (i / n) * upTo;
    final th = f * 2 * math.pi;
    final r = (300 + 110 * math.cos(2 * th) + 70 * math.sin(th)) * scale;
    final x = r * math.cos(th) + (rnd.nextDouble() - 0.5) * 2 * noiseM;
    final y = r * math.sin(th) + (rnd.nextDouble() - 0.5) * 2 * noiseM;
    out.add((lat0 + dLat + y / mPerDeg, lon0 + x / kx));
  }
  return out;
}

double lengthOf(List<(double, double)> fixes) {
  var d = 0.0;
  for (var i = 1; i < fixes.length; i++) {
    final dy = (fixes[i].$1 - fixes[i - 1].$1) * 111194.9;
    final dx =
        (fixes[i].$2 - fixes[i - 1].$2) *
        111194.9 *
        math.cos(fixes[i].$1 * math.pi / 180);
    d += math.sqrt(dx * dx + dy * dy);
  }
  return d;
}

/// The recorder's distance is filtered, not the sum of the noisy fixes, so
/// [distanceM] (default: the fixes' own length) is what the run reports.
RunFile runOf(
  List<(double, double)> fixes, {
  int stepMs = 1000,
  double? distanceM,
}) {
  final base = fixture('easy_free_run').run;
  final total = distanceM ?? lengthOf(fixes);
  final samples = <Sample>[
    for (var i = 0; i < fixes.length; i++)
      Sample(
        tMs: i * stepMs,
        lat: fixes[i].$1,
        lon: fixes[i].$2,
        distM: total * i / (fixes.length - 1),
      ),
  ];
  return base.copyWith(samples: samples);
}

RouteSignature sig(
  List<(double, double)> f, {
  int stepMs = 1000,
  double? distanceM,
}) => RouteSignature.of(runOf(f, stepMs: stepMs, distanceM: distanceM))!;

/// A noisy lap reporting the length its clean twin has.
RouteSignature noisy({
  double noiseM = 5,
  int seed = 7,
  int n = 400,
  double shift = 0,
  double scale = 1,
  bool reverse = false,
  double upTo = 1,
  int stepMs = 1000,
}) => sig(
  loopFixes(
    n: n,
    noiseM: noiseM,
    seed: seed,
    shift: shift,
    scale: scale,
    reverse: reverse,
    upTo: upTo,
  ),
  stepMs: stepMs,
  distanceM: lengthOf(
    loopFixes(n: n, shift: shift, scale: scale, reverse: reverse, upTo: upTo),
  ),
);

void main() {
  final clean = sig(loopFixes());

  test('the signature is short and carries start, end, box and length', () {
    expect(clean.points.length, lessThanOrEqualTo(RouteSignature.maxPoints));
    expect(clean.points.length, greaterThan(8));
    expect(clean.isLoop, isTrue);
    final (minLat, minLon, maxLat, maxLon) = clean.bbox;
    expect(maxLat, greaterThan(minLat));
    expect(maxLon, greaterThan(minLon));
    expect(clean.lengthM, closeTo(2200, 400));
  });

  test('a signature survives its JSON, and an unreadable one is null', () {
    final back = RouteSignature.fromJson(clean.toJson())!;
    expect(back.points.length, clean.points.length);
    expect(back.start.lat, closeTo(clean.start.lat, 1e-5));
    expect(back.end.lon, closeTo(clean.end.lon, 1e-5));
    expect(RouteMatch.same(clean, back), isTrue);
    expect(RouteSignature.fromJson({'len': 1}), isNull);
    expect(RouteSignature.fromJson('x'), isNull);
  });

  test('no fixes, or under 500 m, is no route', () {
    final base = fixture('easy_free_run').run;
    expect(
      RouteSignature.of(
        base.copyWith(
          samples: [
            for (final s in base.samples) s.copyWith(lat: null, lon: null),
          ],
        ),
      ),
      isNull,
    );
    expect(RouteSignature.of(runOf(loopFixes(upTo: 0.1))), isNull);
  });

  test('the same loop with GPS noise and another sample rate matches', () {
    final again = noisy(n: 700, noiseM: 6, stepMs: 700);
    expect(RouteMatch.same(clean, again), isTrue);
    expect(RouteMatch.same(again, clean), isTrue);
    expect(RouteMatch.similarity(clean, again), greaterThan(0.8));
  });

  test('the same loop run the other way round is a different trail', () {
    final reversed = noisy(reverse: true, noiseM: 4, seed: 3);
    // The ground is the same...
    expect(RouteMatch.similarity(clean, reversed), greaterThan(0.8));
    // ...the trail is not.
    expect(RouteMatch.same(clean, reversed), isFalse);
  });

  test('a loop started at another point matches', () {
    final other = noisy(shift: 0.37, seed: 11);
    expect(RouteMatch.same(clean, other), isTrue);
  });

  test('a point-to-point trail needs both ends to line up', () {
    final a = sig(loopFixes(upTo: 0.6));
    final b = noisy(upTo: 0.6, seed: 5);
    expect(RouteMatch.same(a, b), isTrue);
    // Same ground, one end moved 400 m along the trail: not the same trail.
    final shifted = sig(loopFixes(upTo: 0.6, shift: 0.05));
    expect(RouteMatch.same(a, shifted), isFalse);
  });

  test('a partial overlap is not the same trail', () {
    // Both start at the same point and run the same 1 km, then B takes a
    // different way home: the same length, half the ground.
    final a = loopFixes();
    final half = a.length ~/ 2;
    final b = [
      ...a.sublist(0, half),
      for (var i = half; i < a.length; i++)
        (
          a[i].$1 + 0.0035 * math.sin((i - half) / (a.length - half) * math.pi),
          a[i].$2,
        ),
    ];
    final sa = sig(a);
    final sb = sig(b);
    expect(RouteMatch.similarity(sa, sb), lessThan(0.8));
    expect(RouteMatch.same(sa, sb), isFalse);
  });

  test('a different route, or a very different length, is not the same', () {
    expect(RouteMatch.same(clean, sig(loopFixes(dLat: 0.004))), isFalse);
    // Same shape, a quarter bigger: a longer run over different ground.
    expect(RouteMatch.same(clean, sig(loopFixes(scale: 1.25))), isFalse);
  });

  test('the same trail 4 percent bigger still matches', () {
    expect(RouteMatch.same(clean, noisy(scale: 1.04, noiseM: 3)), isTrue);
  });
}
