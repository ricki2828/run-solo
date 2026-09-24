import 'package:xml/xml.dart';

import '../model/run_file.dart';
import '../run_mode.dart';
import 'import_util.dart';

/// TCX → schema-1 run file (plan §4 W1). `<Lap>` elements become manual laps
/// so a watch-recorded 4x4 keeps its splits; trackpoints become samples.
/// Timezone is unknown in TCX, so `tz` is recorded as UTC.
class TcxImporter {
  const TcxImporter();

  RunFile import(
    String text, {
    RunMode? mode,
    Units units = Units.km,
    String app = 'import:tcx',
  }) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(text);
    } on XmlException catch (e) {
      throw ImportFormatException('not XML: ${e.message}');
    }
    final activity = doc.findAllElements('Activity').firstOrNull;
    if (activity == null) throw ImportFormatException('no <Activity>');
    final lapElements = activity.findElements('Lap').toList();
    if (lapElements.isEmpty) throw ImportFormatException('no <Lap>');

    final points = <ImportPoint>[];
    for (final lap in lapElements) {
      for (final tp in lap.findAllElements('Trackpoint')) {
        final timeText = tp.getElement('Time')?.innerText;
        final time = timeText == null ? null : DateTime.tryParse(timeText);
        if (time == null) continue;
        final pos = tp.getElement('Position');
        final lat = _num(pos?.getElement('LatitudeDegrees'));
        final lon = _num(pos?.getElement('LongitudeDegrees'));
        points.add(
          ImportPoint(
            time: time.toUtc(),
            lat: lat,
            lon: lon,
            alt: _num(tp.getElement('AltitudeMeters')),
            dist: _num(tp.getElement('DistanceMeters')),
            hr: _num(tp.getElement('HeartRateBpm')?.getElement('Value'))
                ?.round(),
          ),
        );
      }
    }
    if (points.isEmpty) {
      throw ImportFormatException('no <Trackpoint> with Time');
    }
    points.sort((a, b) => a.time.compareTo(b.time));
    final start = points.first.time;
    final samples = buildSamples(points, start);

    final laps = <Lap>[];
    final trace = _DistLookup(samples);
    for (var i = 0; i < lapElements.length; i++) {
      final el = lapElements[i];
      final startText = el.getAttribute('StartTime');
      final lapStart = startText == null ? null : DateTime.tryParse(startText);
      final total = _num(el.getElement('TotalTimeSeconds'));
      if (lapStart == null) {
        throw ImportFormatException('lap $i has no StartTime');
      }
      var t0 = lapStart.toUtc().difference(start).inMilliseconds;
      if (t0 < 0) t0 = 0;
      int t1;
      if (i + 1 < lapElements.length) {
        final nextText = lapElements[i + 1].getAttribute('StartTime');
        final next = nextText == null ? null : DateTime.tryParse(nextText);
        t1 = next == null
            ? t0 + ((total ?? 0) * 1000).round()
            : next.toUtc().difference(start).inMilliseconds;
      } else {
        t1 = total == null ? samples.last.tMs : t0 + (total * 1000).round();
      }
      if (t1 < t0) t1 = t0;
      if (laps.isNotEmpty && t0 < laps.last.t1Ms) t0 = laps.last.t1Ms;
      if (t1 < t0) t1 = t0;
      laps.add(
        Lap(
          index: i,
          t0Ms: t0,
          t1Ms: t1,
          d0M: trace.at(t0),
          d1M: trace.at(t1),
          kind: LapKind.manual,
        ),
      );
    }

    final device =
        doc
            .findAllElements('Creator')
            .firstOrNull
            ?.getElement('Name')
            ?.innerText
            .trim() ??
        'unknown';
    return RunFile(
      id: deterministicUuid(text),
      device: device,
      app: app,
      start: start,
      end: start.add(Duration(milliseconds: samples.last.tMs)),
      tz: 'UTC',
      mode: mode ?? (laps.length >= 3 ? RunMode.fourByFour : RunMode.free),
      preset: null,
      units: units,
      laps: laps,
      samples: samples,
    );
  }

  static double? _num(XmlElement? el) {
    if (el == null) return null;
    return double.tryParse(el.innerText.trim());
  }
}

class ImportPoint {
  const ImportPoint({
    required this.time,
    this.lat,
    this.lon,
    this.alt,
    this.dist,
    this.hr,
  });
  final DateTime time;
  final double? lat;
  final double? lon;
  final double? alt;
  final double? dist;
  final int? hr;
}

/// Shared by TCX and GPX: sorted points → strictly increasing samples with a
/// cumulative distance (device distance when present, else haversine over
/// points with a fix).
List<Sample> buildSamples(List<ImportPoint> points, DateTime start) {
  final samples = <Sample>[];
  var dist = 0.0;
  double? lastLat;
  double? lastLon;
  var prevT = -1;
  for (final p in points) {
    final t = p.time.difference(start).inMilliseconds;
    if (t <= prevT) continue;
    prevT = t;
    final hasFix = p.lat != null && p.lon != null;
    if (p.dist != null) {
      if (p.dist! > dist) dist = p.dist!;
    } else if (hasFix && lastLat != null) {
      dist += haversineM(lastLat, lastLon!, p.lat!, p.lon!);
    }
    if (hasFix) {
      lastLat = p.lat;
      lastLon = p.lon;
    }
    samples.add(
      Sample(
        tMs: t,
        lat: hasFix ? p.lat : null,
        lon: hasFix ? p.lon : null,
        altM: p.alt,
        accM: null,
        speedMps: null,
        distM: dist,
        hr: p.hr == null || p.hr! <= 0 ? null : p.hr,
      ),
    );
  }
  if (samples.isEmpty) throw ImportFormatException('no usable points');
  return samples;
}

class _DistLookup {
  _DistLookup(this.samples);
  final List<Sample> samples;

  double at(int tMs) {
    if (tMs <= samples.first.tMs) return samples.first.distM;
    if (tMs >= samples.last.tMs) return samples.last.distM;
    var lo = 0;
    var hi = samples.length - 1;
    while (lo < hi - 1) {
      final mid = (lo + hi) >> 1;
      if (samples[mid].tMs <= tMs) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final a = samples[lo];
    final b = samples[hi];
    final f = (tMs - a.tMs) / (b.tMs - a.tMs);
    return a.distM + (b.distM - a.distM) * f;
  }
}

/// GPX has no laps: the run imports as a free run unless the caller asks for
/// 4x4, in which case the engine's speed-stream fallback finds the reps.
class GpxPointBuilder {
  const GpxPointBuilder._();

  static List<Sample> samplesFrom(Iterable<XmlElement> trkpts) {
    final points = <ImportPoint>[];
    for (final tp in trkpts) {
      final timeText = tp.getElement('time')?.innerText;
      final time = timeText == null ? null : DateTime.tryParse(timeText);
      if (time == null) continue;
      final lat = double.tryParse(tp.getAttribute('lat') ?? '');
      final lon = double.tryParse(tp.getAttribute('lon') ?? '');
      final hrEl = tp.findAllElements('hr', namespace: '*').firstOrNull;
      points.add(
        ImportPoint(
          time: time.toUtc(),
          lat: lat,
          lon: lon,
          alt: double.tryParse(tp.getElement('ele')?.innerText.trim() ?? ''),
          hr: hrEl == null ? null : int.tryParse(hrEl.innerText.trim()),
        ),
      );
    }
    if (points.isEmpty) throw ImportFormatException('no <trkpt> with time');
    points.sort((a, b) => a.time.compareTo(b.time));
    return buildSamples(points, points.first.time);
  }

  static DateTime? firstTime(Iterable<XmlElement> trkpts) {
    DateTime? first;
    for (final tp in trkpts) {
      final timeText = tp.getElement('time')?.innerText;
      final time = timeText == null ? null : DateTime.tryParse(timeText);
      if (time != null && (first == null || time.isBefore(first))) {
        first = time.toUtc();
      }
    }
    return first;
  }
}
