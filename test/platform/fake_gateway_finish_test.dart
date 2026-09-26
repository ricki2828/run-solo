import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/platform_api.g.dart';

/// #90: the paused notification's "tap to finish", as the app sees it.
void main() {
  test('emitFinishRequested pauses, counts, and sends a state event', () async {
    final g = FakeRecorderGateway();
    await g.start(RecordMode.free, null, Units.km);
    expect((await g.status()).finishRequests, isNull);
    final states = <RecorderState>[];
    final sub = g.events.listen((e) {
      if (e is StateEvent) states.add(e.state);
    });
    await g.emitFinishRequested();
    await g.emitFinishRequested(); // already paused: counts again, still a state event
    await Future<void>.delayed(Duration.zero);
    final s = await g.status();
    expect(s.state, RecorderState.paused);
    expect(s.finishRequests, 2);
    expect(states, [RecorderState.paused, RecorderState.paused]);
    await sub.cancel();
  });
}
