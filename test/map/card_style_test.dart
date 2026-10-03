@Timeout(Duration(seconds: 30))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/theme/tokens.dart';

double _lum(Color c) {
  double ch(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

double _contrast(Color a, Color b) {
  final la = _lum(a), lb = _lum(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

Color _hex(String s) =>
    Color(0xFF000000 | int.parse(s.substring(1), radix: 16));

void main() {
  final style = jsonDecode(
    File('assets/maps/night_session_card.json').readAsStringSync(),
  ) as List;

  String? colour(String feature, String element) {
    for (final e in style) {
      if (e['featureType'] == feature && e['elementType'] == element) {
        for (final s in e['stylers'] as List) {
          if (s['color'] != null) return s['color'] as String;
        }
      }
    }
    return null;
  }

  test('card style: valid, roads lighter than Night Session, labels on', () {
    final night = jsonDecode(
      File('assets/maps/night_session.json').readAsStringSync(),
    ) as List;
    String? nightRoad(String f) {
      for (final e in night) {
        if (e['featureType'] == f && e['elementType'] == 'geometry.fill') {
          return e['stylers'][0]['color'] as String;
        }
      }
      return null;
    }

    for (final f in ['road.local', 'road.arterial', 'road.highway']) {
      expect(
        _lum(_hex(colour(f, 'geometry.fill')!)),
        greaterThan(_lum(_hex(nightRoad(f)!))),
        reason: f,
      );
    }
    // Water leans blue, parks lean green, both still near black.
    final water = _hex(colour('water', 'geometry')!);
    expect(water.b, greaterThan(water.r));
    final park = _hex(colour('poi.park', 'geometry')!);
    expect(park.g, greaterThan(park.r));
    expect(park.g, lessThan(0.2));
    // Suburb names visible: the card style does not hide them.
    expect(colour('administrative.locality', 'labels.text.fill'), isNotNull);
    expect(colour('poi.park', 'labels.text.fill'), isNotNull);
  });

  test('every run-type route colour is >= 3:1 against the brightest road', () {
    // The card dims the map by 10 % of bgBase; test against the brightest
    // road after that, and the brightest road colour before it.
    final road = _hex(colour('road.highway', 'geometry.fill')!);
    final dimmed = Color.alphaBlend(
      NightSession.bgBase.withValues(alpha: 0.1),
      road,
    );
    final routes = {
      'free': AuroraRunType.free,
      'laps': AuroraRunType.laps,
      'goal': AuroraRunType.goal,
      'intervals': AuroraRunType.intervals,
      'tests': AuroraRunType.tests,
      'trail': AuroraRunType.trail,
      'ink': NightSession.inkPrimary,
    };
    routes.forEach((name, c) {
      expect(_contrast(c, road), greaterThanOrEqualTo(3.0), reason: name);
      expect(_contrast(c, dimmed), greaterThanOrEqualTo(3.0), reason: name);
    });
  });
}
