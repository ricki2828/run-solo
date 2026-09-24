import 'package:xml/xml.dart';

import '../model/run_file.dart';

/// Run file → TCX (plan §4 export): laps + trackpoints + HR. **Home-trim**
/// is on by default and applies to TCX only: positions are dropped for the
/// first and last [homeTrimM] metres; distance and time are kept.
class TcxExporter {
  const TcxExporter({this.homeTrim = true, this.homeTrimM = 200});

  final bool homeTrim;
  final double homeTrimM;

  /// `<Notes>` carries the run's uuid so an own export re-imports with the
  /// same id and dedupes.
  static const String notesPrefix = 'runsolo:';

  String export(RunFile run) {
    final total = run.distanceM;
    bool keepPosition(Sample s) {
      if (!homeTrim) return true;
      if (s.distM < homeTrimM) return false;
      if (total - s.distM < homeTrimM) return false;
      return true;
    }

    final laps = run.laps.where((l) => l.kind != LapKind.pause).toList();
    final lapSpans = laps.isEmpty
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

    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element(
      'TrainingCenterDatabase',
      nest: () {
        builder.attribute(
          'xmlns',
          'http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2',
        );
        builder.element(
          'Activities',
          nest: () {
            builder.element(
              'Activity',
              nest: () {
                builder.attribute('Sport', 'Running');
                builder.element('Id', nest: _iso(run.start));
                for (final lap in lapSpans) {
                  builder.element(
                    'Lap',
                    nest: () {
                      builder.attribute(
                        'StartTime',
                        _iso(run.start.add(Duration(milliseconds: lap.t0Ms))),
                      );
                      builder.element(
                        'TotalTimeSeconds',
                        nest: (lap.durationMs / 1000).toStringAsFixed(1),
                      );
                      builder.element(
                        'DistanceMeters',
                        nest: lap.distanceM.toStringAsFixed(1),
                      );
                      builder.element('Calories', nest: '0');
                      builder.element('Intensity', nest: 'Active');
                      builder.element(
                        'TriggerMethod',
                        nest: lap.kind == LapKind.manual ? 'Manual' : 'Time',
                      );
                      builder.element(
                        'Track',
                        nest: () {
                          for (final s in run.samples) {
                            if (s.tMs < lap.t0Ms || s.tMs >= lap.t1Ms) {
                              if (!(lap == lapSpans.last &&
                                  s.tMs == lap.t1Ms)) {
                                continue;
                              }
                            }
                            builder.element(
                              'Trackpoint',
                              nest: () {
                                builder.element(
                                  'Time',
                                  nest: _iso(
                                    run.start.add(
                                      Duration(milliseconds: s.tMs),
                                    ),
                                  ),
                                );
                                if (s.hasFix && keepPosition(s)) {
                                  builder.element(
                                    'Position',
                                    nest: () {
                                      builder.element(
                                        'LatitudeDegrees',
                                        nest: s.lat!.toStringAsFixed(6),
                                      );
                                      builder.element(
                                        'LongitudeDegrees',
                                        nest: s.lon!.toStringAsFixed(6),
                                      );
                                    },
                                  );
                                }
                                if (s.altM != null) {
                                  builder.element(
                                    'AltitudeMeters',
                                    nest: s.altM!.toStringAsFixed(1),
                                  );
                                }
                                builder.element(
                                  'DistanceMeters',
                                  nest: s.distM.toStringAsFixed(1),
                                );
                                if (s.hr != null) {
                                  builder.element(
                                    'HeartRateBpm',
                                    nest: () {
                                      builder.element('Value', nest: '${s.hr}');
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
                }
                builder.element('Notes', nest: '$notesPrefix${run.id}');
                builder.element(
                  'Creator',
                  nest: () {
                    builder.attribute('xsi:type', 'Device_t');
                    builder.attribute(
                      'xmlns:xsi',
                      'http://www.w3.org/2001/XMLSchema-instance',
                    );
                    builder.element('Name', nest: run.device);
                  },
                );
              },
            );
          },
        );
      },
    );
    return builder.buildDocument().toXmlString(pretty: true, indent: ' ');
  }

  static String _iso(DateTime t) {
    final u = t.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    final ms = u.millisecond.toString().padLeft(3, '0');
    return '${u.year}-${two(u.month)}-${two(u.day)}T${two(u.hour)}:'
        '${two(u.minute)}:${two(u.second)}.${ms}Z';
  }
}
