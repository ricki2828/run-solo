import 'package:xml/xml.dart';

import '../model/run_file.dart';
import 'tcx_exporter.dart';

/// Run file → GPX 1.1 (Send runs, share a file). One `<trkseg>` per lap, so
/// lap boundaries survive in the structure; heart rate rides in the Garmin
/// TrackPointExtension, which Strava, Intervals.icu and most watches read.
/// A GPX point needs a position, so a sample without a fix is left out.
/// **Home-trim** matches [TcxExporter]: no points for the first and last
/// [homeTrimM] metres.
class GpxExporter {
  const GpxExporter({this.homeTrim = true, this.homeTrimM = 200});

  final bool homeTrim;
  final double homeTrimM;

  static const String creator = 'Run Supreme';

  String export(RunFile run, {String? name}) {
    final total = run.distanceM;
    bool keep(Sample s) {
      if (!s.hasFix) return false;
      if (!homeTrim) return true;
      return s.distM >= homeTrimM && total - s.distM >= homeTrimM;
    }

    final laps = run.laps.where((l) => l.kind != LapKind.pause).toList();
    final spans = laps.isEmpty
        ? [
            Lap(
              index: 0,
              t0Ms: 0,
              t1Ms: run.elapsedMs,
              d0M: 0,
              d1M: total,
              kind: LapKind.auto,
            ),
          ]
        : laps;

    final b = XmlBuilder();
    b.processing('xml', 'version="1.0" encoding="UTF-8"');
    b.element(
      'gpx',
      nest: () {
        b.attribute('version', '1.1');
        b.attribute('creator', creator);
        b.attribute('xmlns', 'http://www.topografix.com/GPX/1/1');
        b.attribute(
          'xmlns:gpxtpx',
          'http://www.garmin.com/xmlschemas/TrackPointExtension/v1',
        );
        b.element(
          'metadata',
          nest: () => b.element('time', nest: TcxExporter.isoUtc(run.start)),
        );
        b.element(
          'trk',
          nest: () {
            if (name != null) b.element('name', nest: name);
            b.element('type', nest: 'running');
            for (final lap in spans) {
              b.element(
                'trkseg',
                nest: () {
                  for (final s in run.samples) {
                    final inLap =
                        s.tMs >= lap.t0Ms &&
                        (s.tMs < lap.t1Ms ||
                            (lap == spans.last && s.tMs == lap.t1Ms));
                    if (!inLap || !keep(s)) continue;
                    b.element(
                      'trkpt',
                      nest: () {
                        b.attribute('lat', s.lat!.toStringAsFixed(6));
                        b.attribute('lon', s.lon!.toStringAsFixed(6));
                        if (s.altM != null) {
                          b.element('ele', nest: s.altM!.toStringAsFixed(1));
                        }
                        b.element(
                          'time',
                          nest: TcxExporter.isoUtc(
                            run.start.add(Duration(milliseconds: s.tMs)),
                          ),
                        );
                        if (s.hr != null) {
                          b.element(
                            'extensions',
                            nest: () => b.element(
                              'gpxtpx:TrackPointExtension',
                              nest: () =>
                                  b.element('gpxtpx:hr', nest: '${s.hr}'),
                            ),
                          );
                        }
                      },
                    );
                  }
                },
              );
            }
          },
        );
      },
    );
    return b.buildDocument().toXmlString(pretty: true, indent: ' ');
  }
}
