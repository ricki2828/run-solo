import 'package:xml/xml.dart';

import '../model/run_file.dart';
import '../run_mode.dart';
import 'import_util.dart';
import 'tcx_importer.dart';

/// GPX → schema-1 run file. GPX carries no laps, so the run has none; as a
/// free run it gets a summary, and with `mode: fourByFour` the engine's
/// speed-stream fallback looks for the reps.
class GpxImporter {
  const GpxImporter();

  RunFile import(
    String text, {
    RunMode mode = RunMode.free,
    Units units = Units.km,
    String app = 'import:gpx',
    String tz = 'UTC',
  }) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(text);
    } on XmlException catch (e) {
      throw ImportFormatException('not XML: ${e.message}');
    }
    final trkpts = doc.findAllElements('trkpt').toList();
    if (trkpts.isEmpty) throw ImportFormatException('no <trkpt>');
    final samples = GpxPointBuilder.samplesFrom(trkpts);
    final start = GpxPointBuilder.firstTime(trkpts)!;
    final creator = doc.rootElement.getAttribute('creator') ?? 'unknown';
    return RunFile(
      id: deterministicUuid(text),
      device: creator,
      app: app,
      start: start,
      end: start.add(Duration(milliseconds: samples.last.tMs)),
      tz: tz,
      mode: mode,
      session: null,
      units: units,
      laps: const [],
      samples: samples,
    );
  }
}
