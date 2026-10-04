import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    #if DEBUG
    // CI smoke: `simctl launch ... -RUN_SOLO_TAB history` picks the first tab. SIMCTL_CHILD_ env
    // did not reach the app, so launch arguments (UserDefaults) are copied into the environment
    // Dart reads (debug builds only).
    if let tab = UserDefaults.standard.string(forKey: "RUN_SOLO_TAB") {
      setenv("RUN_SOLO_TAB", tab, 1)
    }
    #endif
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    PlatformHost.register(with: engineBridge.applicationRegistrar.messenger())
  }
}
