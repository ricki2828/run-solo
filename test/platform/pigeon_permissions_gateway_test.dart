import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/platform/pigeon_gateway.dart';

/// Exercises the real `PermissionsApi` mapping against a mocked host, so a
/// production build's checklist is proven to read what Kotlin returns.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const prefix = 'dev.flutter.pigeon.run_solo.PermissionsApi';
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void mock(String method, Object? Function(Object? args) reply) {
    messenger.setMockDecodedMessageHandler<Object?>(
      BasicMessageChannel<Object?>(
        '$prefix.$method',
        PermissionsApi.pigeonChannelCodec,
      ),
      (message) async => <Object?>[reply(message)],
    );
  }

  tearDown(() {
    for (final m in [
      'permissionStatus',
      'requestPermission',
      'openBatterySettings',
      'openAppSettings',
    ]) {
      messenger.setMockDecodedMessageHandler<Object?>(
        BasicMessageChannel<Object?>(
          '$prefix.$m',
          PermissionsApi.pigeonChannelCodec,
        ),
        null,
      );
    }
  });

  test('permissionStatus maps approximateOnly/locationEnabled', () async {
    mock(
      'permissionStatus',
      (_) => PermissionStatus(
        fineLocation: false,
        approximateOnly: true,
        locationEnabled: false,
        notifications: true,
        bluetooth: false,
        batteryUnrestricted: true,
        gmsAvailable: false,
      ),
    );
    final snap = await PigeonPermissionsGateway().status();
    expect(snap.fineLocation, isFalse);
    expect(snap.coarseOnly, isTrue);
    expect(snap.locationServicesOn, isFalse);
    expect(snap.notifications, isTrue);
    expect(snap.bluetooth, isFalse);
    expect(snap.batteryUnrestricted, isTrue);
    expect(snap.gmsAvailable, isFalse);
    expect(snap.canRecord, isFalse);
  });

  test('a granted status can record', () async {
    mock(
      'permissionStatus',
      (_) => PermissionStatus(
        fineLocation: true,
        approximateOnly: false,
        locationEnabled: true,
        notifications: true,
        bluetooth: true,
        batteryUnrestricted: true,
        gmsAvailable: true,
      ),
    );
    expect((await PigeonPermissionsGateway().status()).canRecord, isTrue);
  });

  test('requestPermission passes the kind and returns the grant', () async {
    Object? seen;
    mock('requestPermission', (args) {
      seen = (args as List<Object?>).first;
      return true;
    });
    final granted = await PigeonPermissionsGateway().request(
      PermissionKind.bluetooth,
    );
    expect(granted, isTrue);
    expect(seen, PermissionKind.bluetooth);
  });

  test('openBatterySettings / openAppSettings reach the host', () async {
    var battery = 0, app = 0;
    mock('openBatterySettings', (_) => battery++);
    mock('openAppSettings', (_) => app++);
    final g = PigeonPermissionsGateway();
    await g.openBatterySettings();
    await g.openAppSettings();
    expect(battery, 1);
    expect(app, 1);
  });
}
