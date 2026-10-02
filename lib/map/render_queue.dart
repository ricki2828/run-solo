/// One offscreen map render at a time. Each render is a full platform view
/// plus a snapshot, so Home's cards take turns instead of stacking several
/// live maps. A card that goes away while queued gives its place up.
library;

import 'dart:async';

class RenderQueue {
  RenderQueue();

  /// The app-wide queue the real map surface uses.
  static final RenderQueue shared = RenderQueue();

  final List<RenderTicket> _waiting = [];
  RenderTicket? _active;

  /// Number of renders running (0 or 1) plus waiting; for tests.
  int get pending => _waiting.length + (_active == null ? 0 : 1);

  RenderTicket enqueue() {
    final t = RenderTicket._(this);
    _waiting.add(t);
    _pump();
    return t;
  }

  void _pump() {
    if (_active != null || _waiting.isEmpty) return;
    final next = _waiting.removeAt(0);
    _active = next;
    next._turn.complete(true);
  }

  void _finished(RenderTicket t) {
    if (identical(_active, t)) {
      _active = null;
      _pump();
    } else if (_waiting.remove(t)) {
      t._turn.complete(false);
    }
  }
}

class RenderTicket {
  RenderTicket._(this._queue);
  final RenderQueue _queue;
  final Completer<bool> _turn = Completer<bool>();
  bool _done = false;

  /// Completes true when it is this ticket's turn, false if it was released
  /// while still waiting.
  Future<bool> get turn => _turn.future;

  /// Give up the place (waiting) or the render slot (running). Idempotent.
  void release() {
    if (_done) return;
    _done = true;
    _queue._finished(this);
  }
}
