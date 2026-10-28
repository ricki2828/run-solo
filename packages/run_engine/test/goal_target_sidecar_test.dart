import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

void main() {
  const id = '11111111-2222-4333-8444-555555555555';

  test('a goal target round-trips through the sidecar, eased and old re-aim included', () {
    const g = GoalTargetRecord(
      targetMs: 2402600,
      source: '5K on 26 Oct',
      retargetMs: 3000000,
      eased: true,
    );
    final s = const RunSidecar(runId: id).copyWith(goalTarget: g);
    expect(s.isEmpty, isFalse);
    final back = RunSidecarCodec.decode(RunSidecarCodec.encode(s));
    expect(back.goalTarget, g);
    // Other edits keep it.
    expect(back.copyWith(title: 'x').goalTarget, g);
    expect(back.copyWith(goalTarget: null).goalTarget, isNull);
  });

  test('no target writes no key, and a malformed one reads as none', () {
    final plain = RunSidecarCodec.encode(const RunSidecar(runId: id));
    expect(plain.contains('goal_target'), isFalse);
    for (final bad in [
      '"goal_target": 5',
      '"goal_target": {"target_ms": "x"}',
      '"goal_target": {"target_ms": 0}',
    ]) {
      final text = plain.replaceFirst('{', '{$bad,');
      expect(RunSidecarCodec.decode(text).goalTarget, isNull, reason: bad);
    }
  });

  test('withRetarget keeps the first re-aim when the next answer has none', () {
    const g = GoalTargetRecord(targetMs: 2400000);
    expect(g.withRetarget(3000000).retargetMs, 3000000);
    expect(g.withRetarget(3000000).withRetarget(null).retargetMs, 3000000);
    expect(g.withRetarget(3000000).withRetarget(3180000).retargetMs, 3180000);
  });

  test('eased writes only when set, and an old sidecar reads as not eased', () {
    const plain = GoalTargetRecord(targetMs: 2400000);
    final text = RunSidecarCodec.encode(
      const RunSidecar(runId: id).copyWith(goalTarget: plain),
    );
    expect(text.contains('eased'), isFalse);
    expect(RunSidecarCodec.decode(text).goalTarget!.eased, isFalse);
    expect(plain.withEased().eased, isTrue);
    expect(plain.withEased().withEased(), plain.withEased());
  });
}
