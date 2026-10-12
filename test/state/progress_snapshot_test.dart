import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/state/progress_snapshot.dart';

void main() {
  test('fixtures cover day 1, week 2 and month 3', () {
    final day1 = ProgressSnapshot.sample('day1');
    final week2 = ProgressSnapshot.sample('week2');
    final month3 = ProgressSnapshot.sample('month3');
    expect(day1.runCount, 0);
    expect(day1.level.calibrating, isTrue);
    expect(week2.firsts, hasLength(kFirstsTotal));
    expect(week2.firstsDone, 4);
    expect(week2.pack!.fasterThanInTen, 4);
    expect(month3.pack!.histogram, hasLength(20));
    expect(month3.story!.dailyKm, hasLength(7));
    expect(month3.streak.recent, hasLength(8));
  });
}
