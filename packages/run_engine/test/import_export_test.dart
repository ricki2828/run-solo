import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

import 'helpers.dart';

void main() {
  final run = fixture('four_by_four_manual_clean_hr').run;

  group('TCX export', () {
    test('home-trim drops positions for the first and last 200 m only', () {
      final text = const TcxExporter().export(run);
      final doc = XmlDocument.parse(text);
      final tps = doc.findAllElements('Trackpoint').toList();
      expect(tps.length, run.samples.length);
      final total = run.distanceM;
      for (final tp in tps) {
        final d = double.parse(tp.getElement('DistanceMeters')!.innerText);
        final hasPos = tp.getElement('Position') != null;
        final inside = d >= 200 && total - d >= 200;
        expect(hasPos, inside, reason: 'at ${d}m');
        expect(tp.getElement('HeartRateBpm'), isNotNull);
      }
      expect(doc.findAllElements('Lap').length, run.laps.length);
      expect(
        doc.findAllElements('Lap').first.getElement('TriggerMethod')!.innerText,
        'Manual',
      );
    });

    test('trimming off keeps every position', () {
      final text = const TcxExporter(homeTrim: false).export(run);
      final doc = XmlDocument.parse(text);
      expect(
        doc.findAllElements('Position').length,
        run.samples.where((s) => s.hasFix).length,
      );
    });

    test('JSON export is never trimmed', () {
      final back = RunFileCodec.decode(RunFileCodec.encode(run));
      expect(back.samples.first.lat, run.samples.first.lat);
      expect(back.samples.last.lat, run.samples.last.lat);
    });
  });

  group('TCX import', () {
    final tcx = const TcxExporter(homeTrim: false).export(run);

    test('keeps laps, samples, HR and start time', () {
      final imported = const TcxImporter().import(tcx);
      expect(imported.laps.length, run.laps.length);
      expect(imported.laps.every((l) => l.kind == LapKind.manual), isTrue);
      expect(imported.samples.length, run.samples.length);
      expect(imported.start, run.start);
      expect(imported.hasHr, isTrue);
      expect(imported.mode, RunMode.fourByFour);
      expect(imported.device, 'synthetic');
      expect(imported.distanceM, closeTo(run.distanceM, 0.5));
      for (var i = 0; i < run.laps.length; i++) {
        expect(imported.laps[i].t0Ms, run.laps[i].t0Ms);
        expect(imported.laps[i].t1Ms, run.laps[i].t1Ms);
      }
      // Passes strict validation and the engine reaches the same verdict.
      RunFileCodec.decode(RunFileCodec.encode(imported));
      final a = engine.analyze(imported, now: fixedNow);
      final original = engine.analyze(run, now: fixedNow);
      expect(a.verdict!.headline, original.verdict!.headline);
      expect(
        a.fourByFour!.avgWorkPaceSecPerKm,
        closeTo(original.fourByFour!.avgWorkPaceSecPerKm!, 0.5),
      );
    });

    test('id is deterministic per file and different for different files', () {
      final a = const TcxImporter().import(tcx);
      final b = const TcxImporter().import(tcx);
      expect(a.id, b.id);
      expect(RunFile.uuidPattern.hasMatch(a.id), isTrue);
      final other = const TcxImporter().import(
        const TcxExporter(homeTrim: false)
            .export(fixture('preset_3x4_recovery_2_00').run),
      );
      expect(other.id, isNot(a.id));
    });

    test('without DistanceMeters, distance is haversine over fixes', () {
      final stripped = tcx.replaceAll(
        RegExp(r'<DistanceMeters>[^<]*</DistanceMeters>'),
        '',
      );
      final imported = const TcxImporter().import(stripped);
      expect(imported.distanceM, closeTo(run.distanceM, run.distanceM * 0.01));
    });

    test('rejects non-TCX', () {
      expect(
        () => const TcxImporter().import('<html/>'),
        throwsA(isA<ImportFormatException>()),
      );
      expect(
        () => const TcxImporter().import('not xml <'),
        throwsA(isA<ImportFormatException>()),
      );
      expect(
        () => const TcxImporter().import(
          '<TrainingCenterDatabase><Activities><Activity Sport="Running"><Id>x</Id></Activity></Activities></TrainingCenterDatabase>',
        ),
        throwsA(isA<ImportFormatException>()),
      );
    });

    test('mode can be forced', () {
      expect(
        const TcxImporter().import(tcx, mode: RunMode.free).mode,
        RunMode.free,
      );
    });
  });

  group('GPX import', () {
    String gpxOf(RunFile r, {bool hr = true}) {
      final b = StringBuffer()
        ..writeln('<?xml version="1.0"?>')
        ..writeln(
          '<gpx version="1.1" creator="TestWatch" xmlns="http://www.topografix.com/GPX/1/1" xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">',
        )
        ..writeln('<trk><name>run</name><trkseg>');
      for (final s in r.samples) {
        if (!s.hasFix) continue;
        final t = r.start.add(Duration(milliseconds: s.tMs)).toIso8601String();
        b.write(
          '<trkpt lat="${s.lat}" lon="${s.lon}"><ele>${s.altM ?? 0}</ele><time>$t</time>',
        );
        if (hr && s.hr != null) {
          b.write(
            '<extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>${s.hr}</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions>',
          );
        }
        b.writeln('</trkpt>');
      }
      b.writeln('</trkseg></trk></gpx>');
      return b.toString();
    }

    test('no laps, free run by default, HR from the extension', () {
      final imported = const GpxImporter().import(gpxOf(run));
      expect(imported.laps, isEmpty);
      expect(imported.mode, RunMode.free);
      expect(imported.hasHr, isTrue);
      expect(imported.device, 'TestWatch');
      expect(imported.samples.length, run.samples.length);
      expect(imported.distanceM, closeTo(run.distanceM, run.distanceM * 0.01));
      RunFileCodec.decode(RunFileCodec.encode(imported));
    });

    test('as 4x4 the speed fallback finds the reps', () {
      final imported = const GpxImporter().import(
        gpxOf(run, hr: false),
        mode: RunMode.fourByFour,
      );
      final a = engine.analyze(imported, now: fixedNow);
      expect(a.detection!.fromSpeedStream, isTrue);
      expect(a.fourByFour!.reps.length, 4);
      expect(a.verdict!.headline, VerdictHeadline.baselineSet);
    });

    test('rejects a GPX with no points', () {
      expect(
        () => const GpxImporter().import('<gpx><trk/></gpx>'),
        throwsA(isA<ImportFormatException>()),
      );
    });
  });

  group('uuid dedupe', () {
    test('skips existing ids and repeats within the batch', () {
      final a = fixture('preset_4x4_auto_standard').run;
      final b = fixture('preset_3x4_recovery_2_00').run;
      final plan = planImport([a, b, a], {b.id});
      expect(plan.toImport.map((r) => r.id), [a.id]);
      expect(plan.skippedIds, [b.id, a.id]);
    });

    test('re-importing the same TCX twice is a no-op the second time', () {
      final tcx = const TcxExporter().export(run);
      final first = const TcxImporter().import(tcx);
      final plan = planImport([const TcxImporter().import(tcx)], {first.id});
      expect(plan.toImport, isEmpty);
    });
  });
}
