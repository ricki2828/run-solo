/// The health store seam (Send runs): Health Connect on Android, HealthKit on
/// iOS later. Behind a gateway so widget and unit tests never touch a
/// platform channel. The app only ever writes a finished run; it reads
/// nothing back.
library;

import 'package:flutter/foundation.dart';

import 'platform_api.g.dart';

abstract class HealthGateway {
  /// Never throws: a platform without an implementation says `unsupported`.
  Future<HealthStatus> status();

  /// Ask for the core permissions, or (with [route]) the route permission.
  /// True when that group is granted afterwards.
  Future<bool> requestAccess({required bool route});

  /// Open the store page to install or update Health Connect.
  Future<void> openInstall();

  Future<HealthWriteResult> writeWorkout(HealthWorkout workout);
}

class PigeonHealthGateway implements HealthGateway {
  PigeonHealthGateway({HealthApi? api}) : _api = api ?? HealthApi();
  final HealthApi _api;

  static HealthStatus get _unsupported => HealthStatus(
    availability: HealthAvailability.unsupported,
    coreGranted: false,
    routeGranted: false,
  );

  @override
  Future<HealthStatus> status() async {
    try {
      return await _api.status();
    } catch (e) {
      debugPrint('health: status failed ($e)');
      return _unsupported;
    }
  }

  @override
  Future<bool> requestAccess({required bool route}) async {
    try {
      return await _api.requestAccess(route);
    } catch (e) {
      debugPrint('health: access request failed ($e)');
      return false;
    }
  }

  @override
  Future<void> openInstall() async {
    try {
      await _api.openInstall();
    } catch (e) {
      debugPrint('health: could not open the store ($e)');
    }
  }

  @override
  Future<HealthWriteResult> writeWorkout(HealthWorkout workout) async {
    try {
      return await _api.writeWorkout(workout);
    } catch (e) {
      debugPrint('health: write failed ($e)');
      return HealthWriteResult(
        outcome: HealthWriteOutcome.failed,
        detail: 'Could not write to the health store',
      );
    }
  }
}

class FakeHealthGateway implements HealthGateway {
  FakeHealthGateway({
    this.availability = HealthAvailability.available,
    this.coreGranted = true,
    this.routeGranted = true,
    this.grantCoreOnRequest = true,
    this.grantRouteOnRequest = true,
    this.outcome = HealthWriteOutcome.written,
  });

  HealthAvailability availability;
  bool coreGranted;
  bool routeGranted;

  /// What a permission prompt answers.
  bool grantCoreOnRequest;
  bool grantRouteOnRequest;

  /// What the next write answers.
  HealthWriteOutcome outcome;

  final List<HealthWorkout> written = [];
  final List<bool> requests = [];
  int installOpened = 0;

  @override
  Future<HealthStatus> status() async => HealthStatus(
    availability: availability,
    coreGranted: coreGranted,
    routeGranted: routeGranted,
  );

  @override
  Future<bool> requestAccess({required bool route}) async {
    requests.add(route);
    if (route) {
      routeGranted = grantRouteOnRequest;
      return routeGranted;
    }
    coreGranted = grantCoreOnRequest;
    return coreGranted;
  }

  @override
  Future<void> openInstall() async => installOpened += 1;

  @override
  Future<HealthWriteResult> writeWorkout(HealthWorkout workout) async {
    written.add(workout);
    return HealthWriteResult(outcome: outcome);
  }
}
