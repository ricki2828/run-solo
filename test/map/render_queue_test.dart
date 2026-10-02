@Timeout(Duration(seconds: 30))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/map/render_queue.dart';

void main() {
  test('only one ticket runs at a time, in order', () async {
    final q = RenderQueue();
    final a = q.enqueue();
    final b = q.enqueue();
    final c = q.enqueue();
    final order = <String>[];
    a.turn.then((_) => order.add('a'));
    b.turn.then((_) => order.add('b'));
    c.turn.then((_) => order.add('c'));
    await Future<void>.delayed(Duration.zero);
    expect(order, ['a']);
    a.release();
    await Future<void>.delayed(Duration.zero);
    expect(order, ['a', 'b']);
    b.release();
    c.release();
    expect(q.pending, 0);
  });

  test('a queued ticket released early is skipped and told false', () async {
    final q = RenderQueue();
    final a = q.enqueue();
    final b = q.enqueue();
    final c = q.enqueue();
    b.release();
    expect(await b.turn, isFalse);
    a.release();
    expect(await c.turn, isTrue);
    expect(q.pending, 1);
  });

  test('release is idempotent', () async {
    final q = RenderQueue();
    final a = q.enqueue();
    final b = q.enqueue();
    a.release();
    a.release();
    expect(await b.turn, isTrue);
    expect(q.pending, 1);
  });
}
