import 'dart:convert';
import 'dart:typed_data';

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

FitRecord one(List<FitRecord> rs, int mesg) =>
    rs.singleWhere((r) => r.mesgNum == mesg);

List<FitRecord> steps(List<FitRecord> rs) =>
    rs.where((r) => r.mesgNum == 27).toList();

void main() {
  final created = DateTime.utc(2026, 10, 4, 9);

  group('CRC and framing', () {
    test('CRC-16/ARC check value', () {
      expect(FitCrc.of(ascii.encode('123456789')), 0xBB3D);
    });

    test('header, header CRC, data size and file CRC are right', () {
      final w = FitWorkout.fromSession(SessionSpec.norwegian4x4())!;
      final b = FitWorkoutEncoder.encode(w, created: created);
      final v = ByteData.sublistView(b);
      expect(b[0], 14);
      expect(b[1], 0x20);
      expect(v.getUint16(2, Endian.little), FitWriter.profileVersion);
      expect(ascii.decode(b.sublist(8, 12)), '.FIT');
      expect(v.getUint32(4, Endian.little), b.length - 14 - 2);
      expect(v.getUint16(12, Endian.little), FitCrc.of(b, 0, 12));
      expect(
        v.getUint16(b.length - 2, Endian.little),
        FitCrc.of(b, 0, b.length - 2),
      );
    });

    test('a flipped byte fails the file CRC', () {
      final w = FitWorkout.fromSession(SessionSpec.norwegian4x4())!;
      final b = FitWorkoutEncoder.encode(w, created: created);
      b[30] ^= 0xFF;
      expect(() => FitDecoder.decode(b), throwsA(isA<FitFormatException>()));
    });

    test('FIT timestamp counts from 1989-12-31', () {
      expect(FitWriter.fitTimestamp(DateTime.utc(1989, 12, 31)), 0);
      expect(FitWriter.fitTimestamp(DateTime.utc(1990, 1, 1)), 86400);
    });
  });

  group('workout round trip', () {
    test('file_id and workout messages', () {
      final w = FitWorkout.fromSession(SessionSpec.norwegian4x4())!;
      final rs = FitDecoder.decode(
        FitWorkoutEncoder.encode(w, created: created),
      );
      final id = one(rs, 0).fields;
      expect(id[0], 5); // workout
      expect(id[4], FitWriter.fitTimestamp(created));
      final wk = one(rs, 26).fields;
      expect(wk[4], 1); // running
      expect(wk[8], 'Norwegian 4x4');
      expect(wk[6], steps(rs).length);
    });

    test('4x4: warm-up open, repeat block of 3, last work, cool-down open', () {
      final w = FitWorkout.fromSession(SessionSpec.norwegian4x4())!;
      final s = steps(
        FitDecoder.decode(FitWorkoutEncoder.encode(w, created: created)),
      );
      expect(s.length, 6);
      // 0 warm-up, open
      expect(s[0].fields[0], 'Warm-up');
      expect(s[0].fields[1], 5);
      expect(s[0].fields[7], 2);
      // 1 work 4:00, 2 recovery 3:00
      expect(s[1].fields[1], 0);
      expect(s[1].fields[2], 240000);
      expect(s[1].fields[7], 5);
      expect(s[2].fields[2], 180000);
      expect(s[2].fields[7], 4);
      // 3 repeat from step 1, three times (the 4th work is its own step)
      expect(s[3].fields[1], 6);
      expect(s[3].fields[2], 1);
      expect(s[3].fields[4], 3);
      expect(s[3].fields[7], isNull);
      // 4 last work, 5 cool-down
      expect(s[4].fields[2], 240000);
      expect(s[5].fields[0], 'Cool-down');
      expect(s[5].fields[1], 5);
      for (var i = 0; i < s.length; i++) {
        expect(s[i].fields[254], i);
      }
    });

    test('a repeat step always points back at an earlier step', () {
      final w = FitWorkout.fromSession(SessionSpec.norwegian4x4(reps: 6))!;
      final s = steps(
        FitDecoder.decode(FitWorkoutEncoder.encode(w, created: created)),
      );
      for (final r in s.where((r) => r.fields[1] == 6)) {
        expect((r.fields[2]! as int) < (r.fields[254]! as int), isTrue);
        expect(r.fields[4], 5); // 6 reps = repeat 5 + last work
      }
    });

    test('two reps stay flat, no repeat step', () {
      final w = FitWorkout.fromSession(SessionSpec.norwegian4x4(reps: 2))!;
      expect(w.steps.where((s) => s.duration == FitDuration.repeat), isEmpty);
    });

    test('4x4 heart rate band becomes bpm + 100 on work steps only', () {
      final w = FitWorkout.fromSession(SessionSpec.norwegian4x4(), maxHr: 190)!;
      final s = steps(
        FitDecoder.decode(FitWorkoutEncoder.encode(w, created: created)),
      );
      expect(s[1].fields[3], 1); // heart rate
      expect(s[1].fields[4], 0); // custom range
      expect(s[1].fields[5], 162 + 100); // 0.85 * 190 = 161.5
      expect(s[1].fields[6], 181 + 100); // 0.95 * 190 = 180.5, rounds up
      expect(s[2].fields[3], 2); // recovery open
      expect(s[2].fields[5], isNull);
    });

    test('a pace window wins over the heart rate band, in mm/s', () {
      final w = FitWorkout.fromSession(
        SessionSpec.norwegian4x4(),
        maxHr: 190,
        workPace: FitTarget.pace(slowSecPerKm: 250, fastSecPerKm: 240),
      )!;
      final s = steps(
        FitDecoder.decode(FitWorkoutEncoder.encode(w, created: created)),
      );
      expect(s[1].fields[3], 0); // speed
      expect(s[1].fields[5], 4000); // 1e6 / 250 mm/s, the slow edge
      expect(s[1].fields[6], 4167); // 1e6 / 240
    });
  });

  group('other session shapes', () {
    test('no warm-up when warmupSeconds is 0, fixed warm-up in ms', () {
      const base = SessionSpec(
        templateId: 'x',
        templateVersion: 1,
        name: 'X',
        warmupSeconds: 0,
        cooldownSeconds: 600,
        steps: [SessionStep.workDistance(1000, rep: 1)],
      );
      final w = FitWorkout.fromSession(base)!;
      expect(w.steps.first.name, 'Work');
      expect(w.steps.first.duration, FitDuration.distance);
      expect(w.steps.first.durationValue, 100000); // cm
      expect(w.steps.last.durationValue, 600000);
    });

    test('mixed steps stay flat; equal-time recovery copies the work time', () {
      final spec = SessionSpec(
        templateId: 'x',
        templateVersion: 1,
        name: 'Pyramid',
        steps: const [
          SessionStep.work(60, rep: 1),
          SessionStep.recoveryEqualTime(rep: 1),
          SessionStep.work(120, rep: 2),
        ],
      );
      final w = FitWorkout.fromSession(spec)!;
      expect(w.steps.where((s) => s.duration == FitDuration.repeat), isEmpty);
      expect(w.steps[2].durationValue, 60000);
    });

    test('equal-time recovery after a distance rep is the lap button', () {
      final spec = SessionSpec(
        templateId: 'x',
        templateVersion: 1,
        name: 'Y',
        warmupSeconds: 0,
        cooldownSeconds: 0,
        steps: const [
          SessionStep.workDistance(800, rep: 1),
          SessionStep.recoveryEqualTime(rep: 1),
          SessionStep.workDistance(800, rep: 2),
        ],
      );
      expect(FitWorkout.fromSession(spec)!.steps[1].duration, FitDuration.open);
    });

    test('fartlek has no steps to run', () {
      expect(FitWorkout.fromSession(SessionSpec.fartlek), isNull);
    });

    test('every catalogue preset encodes and decodes', () {
      for (final p in SessionCatalogue.presets) {
        final spec = SessionCatalogue.expand(p.id);
        final w = FitWorkout.fromSession(spec);
        if (w == null) continue;
        final rs = FitDecoder.decode(
          FitWorkoutEncoder.encode(w, created: created),
        );
        expect(steps(rs).length, w.steps.length, reason: p.id);
      }
    });
  });

  group('strings and bad input', () {
    test('long names are cut on a character boundary', () {
      final w = FitWorkout(
        name: 'Ünïcödé ' * 10,
        steps: const [
          FitStep(
            name: 'Ünïcödé Ünïcödé Ünïcödé',
            duration: FitDuration.open,
            intensity: FitIntensity.interval,
          ),
        ],
      );
      final rs = FitDecoder.decode(
        FitWorkoutEncoder.encode(w, created: created),
      );
      expect((one(rs, 26).fields[8] as String).startsWith('Ünïcödé'), isTrue);
      expect(utf8.encode(one(rs, 26).fields[8] as String).length, lessThan(32));
      expect(
        utf8.encode(steps(rs).single.fields[0] as String).length,
        lessThan(16),
      );
    });

    test('unusable targets throw', () {
      expect(
        () => FitTarget.pace(slowSecPerKm: 240, fastSecPerKm: 250),
        throwsArgumentError,
      );
      expect(
        () => FitTarget.heartRate(lowBpm: 180, highBpm: 160),
        throwsArgumentError,
      );
    });

    test('a repeat that points forward is refused', () {
      final w = FitWorkout(
        name: 'Bad',
        steps: const [FitStep.repeat(fromIndex: 3, times: 2)],
      );
      expect(
        () => FitWorkoutEncoder.encode(w, created: created),
        throwsArgumentError,
      );
    });
  });
}
