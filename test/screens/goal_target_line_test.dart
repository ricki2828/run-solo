import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/screens/recording_screen.dart';

/// The cool-down card's "TARGET 40:03 · 9:47 OVER": the gap is the
/// difference of the two clocks printed, in whole seconds.
void main() {
  test('over, under, and on it, from whole seconds', () {
    // 2402.6 s prints 40:03; a 49:50.4 finish floors to 49:50.
    expect(
      GoalDoneBlock.targetLine(2402600, 2990400),
      'TARGET 40:03 · 9:47 OVER',
    );
    expect(
      GoalDoneBlock.targetLine(2402600, 2300000),
      'TARGET 40:03 · 1:43 UNDER',
    );
    // Within the same printed second: on it, not "0:00 OVER".
    expect(GoalDoneBlock.targetLine(2402600, 2403900), 'TARGET 40:03 · ON IT');
  });
}
