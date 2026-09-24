import 'package:flutter/material.dart';

import 'app/routes.dart';
import 'app/services.dart';
import 'screens/pairing_screen.dart';
import 'screens/permissions_screen.dart';
import 'screens/recording_screen.dart';
import 'screens/shell_screen.dart';
import 'screens/start_screen.dart';
import 'theme/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // `--dart-define=RUN_SOLO_FAKE=true` runs every screen on the in-process
  // fake so the APK is usable before the Kotlin RecorderService lands.
  final services = kFakePlatform
      ? AppServices.fake()
      : await AppServices.production();
  runApp(RunSoloApp(services: services));
}

class RunSoloApp extends StatelessWidget {
  const RunSoloApp({
    super.key,
    required this.services,
    this.now,
    this.checkRecoveryOnOpen = true,
    this.home,
  });

  final AppServices services;

  /// Test clock; screens fall back to the wall clock.
  final DateTime Function()? now;
  final bool checkRecoveryOnOpen;

  /// Tests can mount a single screen inside the app chrome.
  final Widget? home;

  @override
  Widget build(BuildContext context) {
    return AppServicesScope(
      services: services,
      child: ListenableBuilder(
        listenable: services.settings,
        builder: (context, _) {
          final reduced = services.settings.settings.reducedMotion;
          return MaterialApp(
            title: 'Run Solo',
            debugShowCheckedModeBanner: false,
            theme: runSoloTheme(),
            darkTheme: runSoloTheme(),
            themeMode: ThemeMode.dark,
            builder: (context, child) => reduced
                ? MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(disableAnimations: true),
                    child: child!,
                  )
                : child!,
            home:
                home ??
                ShellScreen(now: now, checkRecoveryOnOpen: checkRecoveryOnOpen),
            onGenerateRoute: (settings) {
              final page = switch (settings.name) {
                Routes.start => const StartScreen(),
                Routes.permissions => PermissionsScreen(
                  onboarding: settings.arguments == true,
                ),
                Routes.pairing => const PairingScreen(),
                Routes.recording => const RecordingScreen(),
                _ => null,
              };
              if (page == null) return null;
              return MaterialPageRoute<bool>(
                builder: (_) => page,
                settings: settings,
              );
            },
          );
        },
      ),
    );
  }
}
