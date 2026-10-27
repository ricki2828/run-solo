import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show LicenseEntryWithLineBreaks, LicenseRegistry, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show DeviceOrientation, SystemChrome, rootBundle;

import 'package:path_provider/path_provider.dart';

import 'app/diagnostics_log.dart';
import 'app/routes.dart';
import 'app/services.dart';
import 'screens/fix_laps_screen.dart';
import 'screens/offline_maps_screen.dart';
import 'screens/pairing_screen.dart';
import 'screens/permissions_screen.dart';
import 'screens/recording_screen.dart';
import 'screens/run_detail_screen.dart';
import 'screens/plan_screen.dart';
import 'screens/settings_screen.dart';
import 'state/settings.dart';
import 'screens/shell_screen.dart';
import 'screens/start_screen.dart';
import 'screens/verdict_screen.dart';
import 'screens/weekly_story_screen.dart';
import 'state/progress_snapshot.dart' show WeeklyStory;
import 'splash/intro_gate.dart';
import 'splash/intro_host.dart';
import 'theme/theme.dart';

/// The bundled fonts' OFL texts, on Flutter's licence page.
void _registerFontLicences() {
  LicenseRegistry.addLicense(() async* {
    for (final (name, file) in const [
      ('Saira Extra Condensed', 'OFL-SairaExtraCondensed.txt'),
      ('Schibsted Grotesk', 'OFL-SchibstedGrotesk.txt'),
    ]) {
      yield LicenseEntryWithLineBreaks([
        name,
      ], await rootBundle.loadString('assets/fonts/$file'));
    }
  });
}

Future<void> main() async {
  // Errors are logged to the phone (never sent) from the first line; the zone
  // catches what the framework and platform hooks miss.
  DiagnosticsLog? log;
  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      // The log must never stop the app starting: without a files dir it
      // keeps its entries in memory.
      Directory dir;
      try {
        dir = Directory(
          '${(await getApplicationSupportDirectory()).path}/diagnostics',
        );
      } catch (_) {
        dir = Directory('${Directory.systemTemp.path}/diagnostics');
      }
      log = DiagnosticsLog(dir)..install();
      await _start();
    },
    (error, stack) {
      log?.record(error, stack, source: 'zone');
      if (kDebugMode) {
        FlutterError.presentError(
          FlutterErrorDetails(exception: error, stack: stack),
        );
      }
    },
  );
}

Future<void> _start() async {
  // Portrait only (Ricki 11-Oct): no landscape layouts exist.
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
  ]);
  _registerFontLicences();
  // `--dart-define=RUN_SOLO_FAKE=true` runs every screen on the in-process
  // fake so the APK is usable before the Kotlin RecorderService lands.
  final services = kFakePlatform
      ? AppServices.fake()
      : await AppServices.production();
  // Decided before the first frame (plan §4): no intro while a run is live
  // or a recovery journal waits. Start-up work runs under the intro.
  final intro = await IntroGate.read(services);
  // The first route is decided here too, so a first launch goes splash,
  // intro, onboarding with no Home frame in between.
  runApp(
    RunSoloApp(
      services: services,
      intro: intro,
      onboarding: !services.settings.settings.onboardingDone,
    ),
  );
}

class RunSoloApp extends StatelessWidget {
  const RunSoloApp({
    super.key,
    required this.services,
    this.now,
    this.checkRecoveryOnOpen = true,
    this.home,
    this.intro = IntroKind.none,
    this.onboarding = false,
  });

  final AppServices services;

  /// Test clock; screens fall back to the wall clock.
  final DateTime Function()? now;
  final bool checkRecoveryOnOpen;

  /// Tests can mount a single screen inside the app chrome.
  final Widget? home;

  /// The Track Bend intro for this cold start; tests default to none.
  final IntroKind intro;

  /// Open on onboarding instead of Home (first launch); tests default to Home.
  final bool onboarding;

  @override
  Widget build(BuildContext context) {
    return AppServicesScope(
      services: services,
      child: ListenableBuilder(
        listenable: services.settings,
        builder: (context, _) {
          final reduced = services.settings.settings.reducedMotion;
          return MaterialApp(
            title: 'Run Supreme',
            debugShowCheckedModeBanner: false,
            theme: runSoloTheme(),
            darkTheme: runSoloTheme(),
            themeMode: ThemeMode.light,
            builder: (context, child) {
              final app = IntroHost(kind: intro, child: child!);
              return reduced
                  ? MediaQuery(
                      data: MediaQuery.of(context)
                          .copyWith(disableAnimations: true),
                      child: app,
                    )
                  : app;
            },
            home:
                home ??
                ShellScreen(
                  now: now,
                  checkRecoveryOnOpen: checkRecoveryOnOpen,
                  onboarding: onboarding,
                ),
            onGenerateRoute: (settings) {
              final page = switch (settings.name) {
                Routes.start => switch (settings.arguments) {
                  // Home's session button: Ready first, on that session.
                  StartArgs(:final preset, :final readyFirst) => StartScreen(
                    preset: preset,
                    readyFirst: readyFirst,
                  ),
                  final AppSettings Function(AppSettings)? preset =>
                    StartScreen(preset: preset),
                  _ => const StartScreen(),
                },
                Routes.permissions => PermissionsScreen(
                  onboarding: settings.arguments == true,
                ),
                Routes.pairing => const PairingScreen(),
                Routes.recording => Theme(
                  data: runSoloTheme(brightness: Brightness.dark),
                  child: const RecordingScreen(),
                ),
                Routes.verdict => VerdictScreen(
                  runId: settings.arguments as String,
                ),
                Routes.verdictJustFinished => VerdictScreen(
                  runId: settings.arguments as String,
                  justFinished: true,
                ),
                Routes.runDetail => RunDetailScreen(
                  runId: settings.arguments as String,
                ),
                Routes.fixLaps => FixLapsScreen(
                  runId: settings.arguments as String,
                ),
                Routes.settings => SettingsScreen(now: now),
                Routes.offlineMaps => const OfflineMapsScreen(),
                Routes.plan => PlanScreen(now: now),
                Routes.weeklyStory => WeeklyStoryScreen(
                  story: settings.arguments is WeeklyStory
                      ? settings.arguments as WeeklyStory
                      : null,
                ),
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
