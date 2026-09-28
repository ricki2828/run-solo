import 'package:run_engine/src/model/session_spec.dart';
import 'package:test/test.dart';

/// The Bronco test spec (manual sets, founder 28-Sep): no steps like the
/// fartlek, its own comparison key, the 5-set shape.
void main() {
  test('bronco spec validates with no steps', () {
    expect(SessionSpec.bronco.validate(), isEmpty);
    expect(SessionSpec.bronco.steps, isEmpty);
    expect(SessionSpec.bronco.templateId, SessionSpec.broncoId);
    expect(SessionSpec.broncoSets, 5);
  });

  test('bronco has its own comparison key, never the fartlek fallback', () {
    expect(ComparisonKey.of(SessionSpec.bronco), ComparisonKey.bronco);
    expect(ComparisonKey.of(SessionSpec.fartlek), ComparisonKey.fartlek);
  });

  test('other empty sessions still fail validation', () {
    const bogus = SessionSpec(
      templateId: 'custom:x',
      templateVersion: 1,
      name: 'x',
      steps: [],
    );
    expect(bogus.validate(), isNotEmpty);
  });
}
