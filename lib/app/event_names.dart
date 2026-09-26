/// The one flavour config for event names (K1). The Saturday 5 km event's
/// name is a registered trademark: debug and dogfood builds may say it (the
/// founder's choice); the `play` flavour must not without written
/// permission, so it uses a neutral name until L5 decides the store name.
/// `tool/check_event_names.sh` fails CI if the word appears anywhere else in
/// app, engine or native copy.
library;

import 'package:flutter/services.dart' show appFlavor;
import 'package:run_engine/run_engine.dart' as engine;

const engine.EventNames kEventNames = appFlavor == 'play'
    ? engine.EventNames.generic
    : engine.EventNames(parkrun: 'parkrun'); // event-name-ok
