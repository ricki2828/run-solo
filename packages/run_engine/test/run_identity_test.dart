import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

void main() {
  group('time of day', () {
    DateTime at(int h, [int m = 0]) => DateTime(2026, 9, 24, h, m);

    test('buckets', () {
      expect(RunIdentity.timeOfDay(at(0)), 'Early');
      expect(RunIdentity.timeOfDay(at(6, 59)), 'Early');
      expect(RunIdentity.timeOfDay(at(7)), 'Morning');
      expect(RunIdentity.timeOfDay(at(10, 59)), 'Morning');
      expect(RunIdentity.timeOfDay(at(11)), 'Lunch');
      expect(RunIdentity.timeOfDay(at(13, 59)), 'Lunch');
      expect(RunIdentity.timeOfDay(at(14)), 'Afternoon');
      expect(RunIdentity.timeOfDay(at(16, 59)), 'Afternoon');
      expect(RunIdentity.timeOfDay(at(17)), 'Evening');
      expect(RunIdentity.timeOfDay(at(20, 59)), 'Evening');
      expect(RunIdentity.timeOfDay(at(21)), 'Night');
      expect(RunIdentity.timeOfDay(at(23, 59)), 'Night');
    });

    test('title joins the word and the session name', () {
      expect(
        RunIdentity.title(at(8), 'Norwegian 4x4'),
        'Morning Norwegian 4x4',
      );
      expect(RunIdentity.title(at(19), 'Free run'), 'Evening Free run');
      expect(RunIdentity.title(at(12), '8 x 400 m'), 'Lunch 8 x 400 m');
    });
  });

  group('recorded offset', () {
    test('local start shifts by the offset; null falls back to the phone', () {
      final start = DateTime.utc(2026, 9, 23, 20);
      final l = RunIdentity.localStart(start, 600);
      expect((l.day, l.hour), (24, 6));
      expect(RunIdentity.timeOfDay(l), 'Early');
      expect(RunIdentity.localStart(start, null), start.toLocal());
    });

    test('offset and place tries round-trip in the sidecar', () {
      const id = '11111111-2222-4333-8444-555555555555';
      final s = RunSidecar(runId: id)
          .copyWith(utcOffsetMin: -300, placeTries: 2);
      final back = RunSidecarCodec.decode(RunSidecarCodec.encode(s));
      expect(back.utcOffsetMin, -300);
      expect(back.placeTries, 2);
      expect(
        RunSidecar(runId: id).toJson().containsKey('place_tries'),
        isFalse,
      );
    });
  });

  group('place reuse', () {
    const albert = (lat: -37.8431, lon: 144.9660, place: 'Albert Park');
    const fitzroy = (lat: -37.7980, lon: 144.9780, place: 'Fitzroy');

    test('reuses a place within 300 m', () {
      // About 220 m north of the Albert Park start.
      expect(
        RunIdentity.reusePlace(-37.8411, 144.9660, [fitzroy, albert]),
        'Albert Park',
      );
    });

    test('does not reuse beyond 300 m', () {
      // About 400 m north.
      expect(RunIdentity.reusePlace(-37.8395, 144.9660, [albert]), isNull);
    });

    test('nearest of two wins', () {
      const near = (lat: -37.8420, lon: 144.9660, place: 'Middle Park');
      expect(
        RunIdentity.reusePlace(-37.8425, 144.9660, [albert, near]),
        'Middle Park',
      );
    });
  });

  group('clean strings', () {
    test('a raw coordinate is never a place', () {
      expect(RunIdentity.cleanPlace('-37.8431, 144.9660'), isNull);
      expect(RunIdentity.cleanPlace('  12 '), isNull);
      expect(RunIdentity.cleanPlace(''), isNull);
      expect(RunIdentity.cleanPlace(null), isNull);
      expect(RunIdentity.cleanPlace(' Albert Park '), 'Albert Park');
    });

    test('rename is trimmed and capped', () {
      expect(RunIdentity.cleanTitle('   '), isNull);
      expect(RunIdentity.cleanTitle(' Hill day '), 'Hill day');
      expect(RunIdentity.cleanTitle('x' * 80)!.length, 40);
    });
  });

  group('street', () {
    const near = (lat: -37.8431, lon: 144.9660, street: 'Lakeside Dr');

    test('reused within 60 m, not at 100 m', () {
      // About 33 m and about 110 m north.
      expect(
        RunIdentity.reuseStreet(-37.8428, 144.9660, [near]),
        'Lakeside Dr',
      );
      expect(RunIdentity.reuseStreet(-37.8421, 144.9660, [near]), isNull);
    });

    test('the nearest known street wins', () {
      const other = (lat: -37.8430, lon: 144.9660, street: 'Albert Rd');
      expect(
        RunIdentity.reuseStreet(-37.84297, 144.9660, [near, other]),
        'Albert Rd',
      );
    });
  });

  group('sidecar', () {
    const id = '11111111-2222-4333-8444-555555555555';

    test('place and title round-trip and survive other edits', () {
      final s = RunSidecar(runId: id)
          .copyWith(place: 'Albert Park', title: 'Hills');
      final back = RunSidecarCodec.decode(RunSidecarCodec.encode(s));
      expect(back.place, 'Albert Park');
      expect(back.title, 'Hills');
      expect(back.withOverride(RunMode.free).title, 'Hills');
      expect(back.isEmpty, isFalse);
    });

    test('street and streetTried round-trip; absent when unset', () {
      final s = RunSidecar(runId: id)
          .copyWith(street: 'Lakeside Dr', streetTried: true);
      final back = RunSidecarCodec.decode(RunSidecarCodec.encode(s));
      expect(back.street, 'Lakeside Dr');
      expect(back.streetTried, isTrue);
      expect(back.isEmpty, isFalse);
      final tried = RunSidecar(runId: id).copyWith(streetTried: true);
      expect(tried.isEmpty, isFalse);
      final plain = RunSidecar(runId: id).toJson();
      expect(plain.containsKey('street'), isFalse);
      expect(plain.containsKey('street_tried'), isFalse);
    });

    test('absent keys are not written and an old sidecar still reads', () {
      final s = RunSidecar(runId: id);
      expect(s.toJson().containsKey('place'), isFalse);
      expect(s.toJson().containsKey('title'), isFalse);
      final old = RunSidecarCodec.decode(RunSidecarCodec.encode(s));
      expect(old.place, isNull);
      expect(old.isEmpty, isTrue);
    });
  });
}
