import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/screens/pairing_screen.dart';
import 'package:run_solo/state/settings.dart';

import '../helpers.dart';

void main() {
  testWidgets('scan lists straps, Whoop carries the broadcast hint', (
    tester,
  ) async {
    final ble = FakeBleGateway();
    final services = fakeServices(ble: ble);
    await pumpApp(tester, services, pushRoute: Routes.pairing);
    await pumpTimes(tester, 4);

    expect(find.text('SCAN'), findsOneWidget);
    expect(find.textContaining('Broadcast heart rate'), findsOneWidget);
    await tester.tap(find.text('SCAN'));
    await pumpTimes(tester, 4);

    expect(find.text('Whoop (broadcast on in Whoop app)'), findsOneWidget);
    expect(find.text('Polar H10 9B2C'), findsOneWidget);
    expect(find.text('SCAN AGAIN'), findsOneWidget);
  });

  testWidgets('tapping a strap pairs, saves it and closes the screen', (
    tester,
  ) async {
    final ble = FakeBleGateway();
    final services = fakeServices(ble: ble);
    await pumpApp(tester, services, pushRoute: Routes.pairing);
    await pumpTimes(tester, 4);
    await tester.tap(find.text('SCAN'));
    await pumpTimes(tester, 4);

    await tester.tap(find.text('Whoop (broadcast on in Whoop app)'));
    await pumpTimes(tester, 6);
    expect(ble.paired?.address, 'C4:2B:11:09:AA:01');
    final strap = services.settings.settings.strap;
    expect(strap?.isWhoop, isTrue);
    expect(strap?.label, 'Whoop');
    await settleAnimations(tester);
    expect(find.byType(PairingScreen), findsNothing);
  });

  testWidgets('a failed Whoop connect explains broadcast', (tester) async {
    final ble = FakeBleGateway()..failNextPair = true;
    final services = fakeServices(ble: ble);
    await pumpApp(tester, services, pushRoute: Routes.pairing);
    await pumpTimes(tester, 4);
    await tester.tap(find.text('SCAN'));
    await pumpTimes(tester, 4);
    await tester.tap(find.text('Whoop (broadcast on in Whoop app)'));
    await pumpTimes(tester, 6);
    expect(
      find.text('Turn on broadcast in the Whoop app, then retry.'),
      findsOneWidget,
    );
    expect(services.settings.settings.strap, isNull);
    expect(find.byType(PairingScreen), findsOneWidget);
  });

  testWidgets('empty scan says so', (tester) async {
    final ble = FakeBleGateway(devices: []);
    final services = fakeServices(ble: ble);
    await pumpApp(tester, services, pushRoute: Routes.pairing);
    await pumpTimes(tester, 4);
    await tester.tap(find.text('SCAN'));
    await pumpTimes(tester, 4);
    expect(find.text('No strap found.'), findsOneWidget);
  });

  testWidgets('saved strap shows with Forget', (tester) async {
    final ble = FakeBleGateway();
    final services = fakeServices(
      ble: ble,
      settings: const AppSettings(
        onboardingDone: true,
        strap: SavedStrap(address: 'AA:BB', name: 'Polar H10'),
      ),
    );
    await pumpApp(tester, services, pushRoute: Routes.pairing);
    await pumpTimes(tester, 4);
    expect(find.text('SAVED'), findsOneWidget);
    expect(find.text('Polar H10'), findsOneWidget);
    await tester.tap(find.text('Forget'));
    await pumpTimes(tester, 4);
    expect(services.settings.settings.strap, isNull);
    expect(find.text('SAVED'), findsNothing);
  });
}
