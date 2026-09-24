/// Flutter side of the Kotlin channel contract (plan §2). Pigeon generates
/// `platform_api.g.dart`; this file only re-exports it and wraps the
/// single-listener EventChannel in a broadcast stream.
library;

import 'platform_api.g.dart';

export 'platform_api.g.dart';

/// The EventChannel has one listener, so the app shares this broadcast stream.
Stream<RecorderEvent>? _recorderEventsBroadcast;

Stream<RecorderEvent> recorderEventStream() =>
    _recorderEventsBroadcast ??= recorderEvents().asBroadcastStream();
