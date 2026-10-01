import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

import 'helpers.dart';

void main() {
  sendLogTests();
  final run = fixture('four_by_four_manual_clean_hr').run;

  group('GPX export', () {
    final gpx = const GpxExporter(homeTrim: false).export(run, name: 'Test');
    final doc = XmlDocument.parse(gpx);

    test('one trkseg per lap, every fix and timestamp present', () {
      expect(doc.findAllElements('trkseg').length, run.laps.length);
      final fixes = run.samples.where((s) => s.hasFix).toList();
      final pts = doc.findAllElements('trkpt').toList();
      expect(pts.length, fixes.length);
      expect(
        DateTime.parse(pts.first.getElement('time')!.innerText),
        run.start.add(Duration(milliseconds: fixes.first.tMs)),
      );
      expect(
        double.parse(pts.first.getAttribute('lat')!),
        closeTo(fixes.first.lat!, 1e-6),
      );
    });

    test('heart rate is in the TrackPointExtension', () {
      final hrs = doc
          .findAllElements('hr', namespace: '*')
          .map((e) => int.parse(e.innerText))
          .toList();
      expect(
        hrs,
        run.samples.where((s) => s.hasFix && s.hr != null).map((s) => s.hr),
      );
    });

    test('round-trips through the importer: points, HR, start, distance', () {
      final back = const GpxImporter().import(gpx);
      expect(back.start, run.start);
      expect(back.hasHr, isTrue);
      expect(back.samples.length, run.samples.where((s) => s.hasFix).length);
      expect(back.distanceM, closeTo(run.distanceM, run.distanceM * 0.02));
    });

    test('home-trim drops the first and last 200 m', () {
      final trimmed = XmlDocument.parse(const GpxExporter().export(run));
      final total = run.distanceM;
      final kept = run.samples
          .where((s) => s.hasFix && s.distM >= 200 && total - s.distM >= 200)
          .length;
      expect(trimmed.findAllElements('trkpt').length, kept);
    });

    test('a run without laps exports one segment', () {
      final noLaps = run.copyWith(laps: const []);
      final d = XmlDocument.parse(
        const GpxExporter(homeTrim: false).export(noLaps),
      );
      expect(d.findAllElements('trkseg').length, 1);
    });
  });

  group('TCX carries what Send needs', () {
    final tcx = const TcxExporter(homeTrim: false).export(run);
    final doc = XmlDocument.parse(tcx);

    test('laps with start time, duration and distance', () {
      final laps = doc.findAllElements('Lap').toList();
      expect(laps.length, run.laps.length);
      for (var i = 0; i < laps.length; i++) {
        expect(
          DateTime.parse(laps[i].getAttribute('StartTime')!),
          run.start.add(Duration(milliseconds: run.laps[i].t0Ms)),
        );
        expect(
          double.parse(laps[i].getElement('TotalTimeSeconds')!.innerText),
          closeTo(run.laps[i].durationMs / 1000, 0.1),
        );
        expect(
          double.parse(laps[i].getElement('DistanceMeters')!.innerText),
          closeTo(run.laps[i].distanceM, 0.1),
        );
      }
    });

    test('per-point time, route and HR', () {
      final tps = doc.findAllElements('Trackpoint').toList();
      expect(tps.length, run.samples.length);
      expect(tps.every((t) => t.getElement('Time') != null), isTrue);
      expect(tps.every((t) => t.getElement('HeartRateBpm') != null), isTrue);
      expect(
        tps.where((t) => t.getElement('Position') != null).length,
        run.samples.where((s) => s.hasFix).length,
      );
    });
  });
}

void sendLogTests() {
  group('send log', () {
    final t0 = DateTime.utc(2026, 10, 2, 8);
    RunSidecar fresh() =>
        RunSidecar(runId: '00000000-0000-4000-8000-000000000001');

    test('never tried: auto send is due', () {
      expect(fresh().autoSendDue('intervals'), isTrue);
    });

    test('a success is never sent again automatically', () {
      final s = fresh().withSend('intervals', ok: true, at: t0);
      expect(s.autoSendDue('intervals'), isFalse);
      expect(s.autoSendDue('other'), isTrue);
    });

    test('failures retry up to the cap, then stop', () {
      var s = fresh();
      for (var i = 1; i <= SendRecord.maxAutoTries; i++) {
        expect(s.autoSendDue('t'), isTrue, reason: 'before attempt $i');
        s = s.withSend('t', ok: false, at: t0, error: 'offline');
      }
      expect(s.sends['t']!.tries, SendRecord.maxAutoTries);
      expect(s.autoSendDue('t'), isFalse);
    });

    test('a later success clears the failure count', () {
      final s = fresh()
          .withSend('t', ok: false, at: t0, error: 'offline')
          .withSend('t', ok: true, at: t0.add(const Duration(minutes: 1)));
      expect(s.sends['t']!.ok, isTrue);
      expect(s.sends['t']!.tries, 0);
      expect(s.sends['t']!.error, isNull);
    });

    test('round-trips through the codec and ignores a damaged entry', () {
      final s = fresh()
          .withSend('a', ok: true, at: t0)
          .withSend('b', ok: false, at: t0, error: 'No network');
      final back = RunSidecarCodec.decode(RunSidecarCodec.encode(s));
      expect(back.sends, s.sends);
      final json = s.toJson();
      json['sends'] = {...(json['sends'] as Map), 'c': 'garbage'};
      final lenient = RunSidecar.fromJson(json);
      expect(lenient.sends.keys, unorderedEquals(['a', 'b']));
      expect(fresh().toJson().containsKey('sends'), isFalse);
      expect(s.isEmpty, isFalse);
    });
  });
}
