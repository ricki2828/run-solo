import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/platform_api.g.dart';

/// The finish screen's gateway calls (#88): DISCARD throws the live run
/// away; SAVE while paused ends the run at the pause, as native does.
void main() {
  test('discard: idle, no finalised run, listed in liveDiscarded', () async {
    final g = FakeRecorderGateway();
    final id = (await g.start(RecordMode.free, null, Units.km)).runId!;
    await g.pause();
    expect(await g.discard(), isTrue);
    expect((await g.status()).state, RecorderState.idle);
    expect(g.finalised, isEmpty);
    expect(g.liveDiscarded, [id]);
    expect(await g.discard(), isFalse, reason: 'nothing on');
  });

  test('stop while paused ends the run at the pause', () async {
    final g = FakeRecorderGateway();
    await g.start(RecordMode.free, null, Units.km);
    g.advance(const Duration(seconds: 40));
    await g.pause();
    g.advance(const Duration(seconds: 20)); // on the finish screen
    await g.stop();
    expect(g.finalised.single.durationMs, 40000);
  });
}
