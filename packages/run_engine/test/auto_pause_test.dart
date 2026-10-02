import 'dart:convert';

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  // A free run to hang auto-pauses on.
  final base = fixture('easy_free_run').run;
  final totalMs = base.end.difference(base.start).inMilliseconds;

  RunFile withPauses(List<Span> pauses) =>
      base.copyWith(pauses: pauses, gaps: const []);

  group('auto-pause spans', () {
    test('movingMs leaves auto-pauses out like manual ones', () {
      final r = withPauses([
        const Span(60000, 90000, auto: true), // a red light
        const Span(300000, 305000), // the runner's own pause
        const Span(600000, 640000, auto: true),
      ]);
      expect(RunTimes.movingMs(r), totalMs - 30000 - 5000 - 40000);
    });

    test('elapsed time does not change', () {
      final r = withPauses([const Span(60000, 90000, auto: true)]);
      expect(r.elapsedMs, base.elapsedMs);
      expect(r.end.difference(r.start).inMilliseconds, totalMs);
    });

    test('an auto-pause overlapping a manual pause is counted once', () {
      final r = withPauses([
        const Span(60000, 90000, auto: true),
        const Span(80000, 100000),
      ]);
      expect(RunTimes.movingMs(r), totalMs - 40000);
    });

    test('moving pace uses moving time, not elapsed', () {
      final stopped = withPauses([const Span(60000, 120000, auto: true)]);
      final a = engine.analyze(stopped, now: fixedNow).freeRun;
      final b = engine.analyze(base, now: fixedNow).freeRun;
      expect(a.elapsedSeconds, b.elapsedSeconds);
      expect(a.movingSeconds, closeTo(b.movingSeconds - 60, 0.001));
      expect(a.distanceM, b.distanceM);
    });
  });

  group('auto-pause codec', () {
    test('an auto span round-trips as [t0, t1, "auto"]', () {
      final r = withPauses([
        const Span(60000, 90000, auto: true),
        const Span(120000, 125000),
      ]);
      final text = RunFileCodec.encode(r);
      final j = jsonDecode(text) as Map<String, Object?>;
      expect(j['pauses'], [
        [60000, 90000, 'auto'],
        [120000, 125000],
      ]);
      final back = RunFileCodec.decode(text);
      expect(back.pauses, r.pauses);
      expect(back.pauses.map((p) => p.auto), [true, false]);
      expect(RunFileCodec.encode(back), text);
    });

    test('a file from before auto-pause reads as manual pauses', () {
      final j = jsonDecode(
        RunFileCodec.encode(withPauses([const Span(1, 2)])),
      ) as Map<String, Object?>;
      final back = RunFileCodec.decode(jsonEncode(j));
      expect(back.pauses.single.auto, isFalse);
    });

    test('a third element that is not "auto" is refused', () {
      final j = jsonDecode(
        RunFileCodec.encode(withPauses([const Span(1, 2)])),
      ) as Map<String, Object?>;
      j['pauses'] = [
        [1, 2, 'manual'],
      ];
      expect(
        () => RunFileCodec.decode(jsonEncode(j)),
        throwsA(isA<RunFileFormatException>()),
      );
    });
  });
}
