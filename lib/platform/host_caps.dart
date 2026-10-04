import 'dart:io';

import 'package:flutter/foundation.dart';

/// What this host can do beyond the Pigeon contract. iPhone Phase 1 has no
/// strap pairing and no Apple Health export yet (iOS plan §7.1); both come
/// back when their Swift hosts land.
class HostCaps {
  const HostCaps._();

  @visibleForTesting
  static bool? iosOverride;

  static bool get isIos => iosOverride ?? Platform.isIOS;

  static bool get strapPairing => !isIos;

  static bool get healthExport => !isIos;
}
