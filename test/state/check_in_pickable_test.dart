import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/state/settings.dart';

void main() {
  test('the picker offers every check-in metric, Way back included', () {
    expect(CheckInMetric.pickable, CheckInMetric.values);
    expect(CheckInMetric.pickable, contains(CheckInMetric.retrace));
    expect(CheckInMetric.retrace.label, 'Way back');
  });

  test('Way back can be turned off and the choice persists', () {
    final off = [
      for (final m in CheckInMetric.pickable)
        if (m != CheckInMetric.retrace) m,
    ];
    final back = AppSettings.fromJson(
      AppSettings(checkInMetrics: off).toJson(),
    );
    expect(back.checkInMetrics, off);
    expect(back.checkInMetrics, isNot(contains(CheckInMetric.retrace)));
  });
}
