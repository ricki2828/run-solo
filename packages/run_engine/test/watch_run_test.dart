import 'dart:convert';
import 'dart:io';

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

/// Schema 8 (Garmin G6): the optional `watch` block, written only for a run a
/// watch recorded (core-jvm `WatchRunImporter`). The `watch_run_*` contract
/// fixtures are that importer's real output.
void main() {
  final dir = Directory('test/fixtures/contract');
  String text(String name) => File('${dir.path}/$name.json').readAsStringSync();
  RunFile load(String name) => RunFileCodec.decode(text(name));
  Map<String, Object?> json(String name) =>
      jsonDecode(text(name)) as Map<String, Object?>;

  const watchFixtures = [
    'watch_run_5s_track',
    'watch_run_thinned',
    'watch_run_two_step_degrade',
    'watch_run_splits_only',
  ];

  group('v8 round trip', () {
    for (final name in watchFixtures) {
      test(
        '$name: read -> write -> read is equal and the bytes are stable',
        () {
          final run = load(name);
          expect(run.readSchema, 8);
          expect(run.watch, isNotNull);
          final again = RunFileCodec.encode(run);
          final back = RunFileCodec.decode(again);
          expect(back.watch, run.watch);
          expect(RunFileCodec.encode(back), again);
        },
      );
    }

    test('the watch block reads as the importer wrote it', () {
      final run = load('watch_run_thinned');
      expect(run.device, 'garmin:forerunner265');
      expect(run.app, 'garmin-watch/0.1.0');
      expect(run.mode, RunMode.free);
      expect(run.watch!.model, 'forerunner265');
      expect(run.watch!.rateChanges, const [
        RateChange(0, 5),
        RateChange(360000, 0),
      ]);
      // The watch's own figures, not a track sum.
      expect(run.distanceM, 1800);
      expect(run.laps.map((l) => l.d1M), [999, 1800]);
      expect(run.coach!.choice, 'chase');
    });

    test('trackThinned is true for more than one rate change only', () {
      expect(load('watch_run_5s_track').watch!.trackThinned, isFalse);
      expect(load('watch_run_splits_only').watch!.trackThinned, isFalse);
      expect(load('watch_run_thinned').watch!.trackThinned, isTrue);
      final two = load('watch_run_two_step_degrade').watch!;
      expect(two.trackThinned, isTrue);
      expect(two.rateChanges, hasLength(3));
    });

    test('a phone-recorded run stays schema 7 with no watch key', () {
      final run = load('free_run_no_laps');
      expect(run.watch, isNull);
      final j = jsonDecode(RunFileCodec.encode(run)) as Map<String, Object?>;
      expect(j['schema'], 7);
      expect(j.containsKey('watch'), isFalse);
      expect(run.writeSchema, 7);
    });
  });

  group('older and newer files', () {
    test('a schema-7 file still reads, with no watch', () {
      final v7 = text('free_run_no_laps');
      expect(v7, contains('"schema":7,'));
      final run = RunFileCodec.decode(v7);
      expect(run.readSchema, 7);
      expect(run.watch, isNull);
      expect(RunFile.minReadSchema, 1);
    });

    test('every frozen schema-7 file (the last phone writer) reads and rewrites as 7', () {
      final files = Directory('${dir.path}/schema7')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList();
      expect(files.length, greaterThanOrEqualTo(6));
      for (final f in files) {
        final run = RunFileCodec.decode(f.readAsStringSync());
        expect(run.readSchema, 7, reason: f.path);
        expect(run.watch, isNull, reason: f.path);
        expect(run.writeSchema, 7, reason: f.path);
        final j = jsonDecode(RunFileCodec.encode(run)) as Map<String, Object?>;
        expect(j['schema'], 7, reason: f.path);
      }
    });

    test('a schema-6 frozen file still reads', () {
      final run = RunFileCodec.decode(
        File('${dir.path}/schema6/free_run_no_laps.json').readAsStringSync(),
      );
      expect(run.readSchema, 6);
      expect(run.watch, isNull);
    });

    test('a watch block in a schema-7 file is malformed', () {
      final j = json('watch_run_5s_track')..['schema'] = 7;
      expect(() => RunFile.fromJson(j), throwsA(isA<RunFileFormatException>()));
    });

    test('a v8 file with a watch block is refused by a schema-7 reader: the key is outside its set', () {
      // A schema-7 build is not in this tree. Its strictness is two checks in
      // `fromJson`: `schema > 7` and any key outside its set. Both hold here.
      const v7Keys = {
        'schema', 'id', 'device', 'app', 'start', 'end', 'tz', 'mode',
        'session', 'units', 'laps', 'pauses', 'gaps', 'samples', 'elev_src',
        'nudges_fired', 'route', 'coach', // ignore: require_trailing_commas
      };
      final j = json('watch_run_5s_track');
      expect(j['schema'], greaterThan(7));
      expect(j.keys.toSet().difference(v7Keys), {'watch'});
    });

    test('this build refuses a newer schema even with a valid watch block', () {
      final j = json('watch_run_5s_track')..['schema'] = 9;
      expect(
        () => RunFile.fromJson(j),
        throwsA(isA<RunFileNewerVersionException>()),
      );
    });
  });

  group('strict watch block', () {
    Object? decodeWatch(Object? watch) {
      final j = json('watch_run_5s_track')..['watch'] = watch;
      return RunFile.fromJson(j).watch;
    }

    Map<String, Object?> watchWith(Object? rateChanges) => {
      'model': 'forerunner265',
      'rateChanges': rateChanges,
    };

    test('an unknown watch key is a newer file', () {
      expect(
        () => decodeWatch({
          ...watchWith([
            [0, 5],
          ]),
          'battery': 80,
        }),
        throwsA(isA<RunFileNewerVersionException>()),
      );
    });

    test('bad rateChanges are malformed', () {
      for (final bad in <Object?>[
        [
          [0, 5],
          [900000, 0],
          [300000, 1],
        ], // descending
        [
          [0, 5],
          [0, 1],
        ], // not strictly ascending
        [
          [5000, 5],
        ], // first not at 0
        [
          [0, -1],
        ], // negative rate
        [
          [-1, 5],
        ], // negative time
        <Object?>[], // empty
        [
          [0],
        ], // wrong arity
        [
          [0, 5.5],
        ], // not an int
        'nope',
      ]) {
        expect(
          () => decodeWatch(watchWith(bad)),
          throwsA(isA<RunFileFormatException>()),
          reason: '$bad',
        );
      }
    });

    test('model must be a non-empty string and watch an object', () {
      for (final bad in <Object?>[
        {
          'model': '',
          'rateChanges': [
            [0, 5],
          ],
        },
        {
          'model': 3,
          'rateChanges': [
            [0, 5],
          ],
        },
        {
          'rateChanges': [
            [0, 5],
          ],
        },
        'garmin',
      ]) {
        expect(
          () => decodeWatch(bad),
          throwsA(isA<RunFileFormatException>()),
          reason: '$bad',
        );
      }
    });
  });

  group('rebuild paths keep the watch block', () {
    test('copyWith (the rescue-edit and lap-fix path) carries it', () {
      final run = load('watch_run_thinned');
      final edited = run.copyWith(laps: [run.laps.first]);
      expect(edited.watch, run.watch);
      expect(edited.laps, hasLength(1));
      expect(
        jsonDecode(RunFileCodec.encode(edited)),
        containsPair('watch', run.watch!.toJson()),
      );
    });

    test('copyWith can clear it explicitly and nothing else does', () {
      final run = load('watch_run_5s_track');
      expect(run.copyWith(watch: null).watch, isNull);
      expect(run.copyWith(mode: RunMode.free).watch, run.watch);
    });

    test('an edited watch run stays schema 8 and a phone run stays 7', () {
      final watch = load('watch_run_thinned');
      final edited = watch.copyWith(laps: [watch.laps.first]);
      expect(edited.writeSchema, 8);
      expect((jsonDecode(RunFileCodec.encode(edited)) as Map)['schema'], 8);
      final phone = load('free_run_no_laps').copyWith(mode: RunMode.free);
      expect(phone.writeSchema, 7);
    });

    test('the export bundle schema follows the file', () {
      int bundleSchema(RunFile r) =>
          (jsonDecode(RunBundleCodec.encode(RunBundle(run: r)))
                  as Map)['schema']
              as int;
      expect(bundleSchema(load('watch_run_thinned')), 8);
      expect(bundleSchema(load('free_run_no_laps')), 7);
    });

    test('an export bundle round-trips it', () {
      final run = load('watch_run_thinned');
      final back = RunBundleCodec.decode(
        RunBundleCodec.encode(RunBundle(run: run)),
      );
      expect(back.run.watch, run.watch);
    });
  });
}
