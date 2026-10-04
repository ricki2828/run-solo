import 'package:xml/xml.dart';

import '../route/saved_route.dart';

/// A saved route as a GPX 1.1 course for a watch to navigate: one named
/// `<trk>` with a single `<trkseg>`, elevation where the route has it. Garmin
/// Connect (web), COROS and Wahoo read tracks as courses. No times, no heart
/// rate, nothing about who ran it.
class GpxCourseExporter {
  const GpxCourseExporter();

  static const String creator = 'Run Supreme';

  String export(SavedRoute route, {String? name}) {
    final title = name ?? route.name;
    final b = XmlBuilder();
    b.processing('xml', 'version="1.0" encoding="UTF-8"');
    b.element(
      'gpx',
      nest: () {
        b.attribute('version', '1.1');
        b.attribute('creator', creator);
        b.attribute('xmlns', 'http://www.topografix.com/GPX/1/1');
        b.element('metadata', nest: () => b.element('name', nest: title));
        b.element(
          'trk',
          nest: () {
            b.element('name', nest: title);
            b.element('type', nest: 'running');
            b.element(
              'trkseg',
              nest: () {
                for (final p in route.points) {
                  b.element(
                    'trkpt',
                    nest: () {
                      b.attribute('lat', p.lat.toStringAsFixed(6));
                      b.attribute('lon', p.lon.toStringAsFixed(6));
                      if (p.ele != null) {
                        b.element('ele', nest: p.ele!.toStringAsFixed(1));
                      }
                    },
                  );
                }
              },
            );
          },
        );
      },
    );
    return b.buildDocument().toXmlString(pretty: true);
  }
}
