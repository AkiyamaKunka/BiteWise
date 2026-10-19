import Flutter
import UIKit
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// MUST equal photoBackfillUniqueName (lib/services/photo/background.dart)
  /// and the Info.plist BGTaskSchedulerPermittedIdentifiers entry: iOS only
  /// launches identifiers registered before didFinishLaunching returns.
  static let photoBackfillIdentifier = "calorietracker.photo.backfill.periodic"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // The background run gets its own Flutter engine; it needs the same
    // plugins (photo library, database, notifications, HTTP) registered.
    // workmanager calls this as it creates that engine, before the engine
    // boots: the moment the run's clock should start from.
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      AppDelegate.stampBackgroundLaunch()
      GeneratedPluginRegistrant.register(with: registry)
      // App-local plugins are not in the generated registrant. The headless
      // engine needs this one most: its GPU is off for the whole run, so
      // HEIC can only be decoded through ImageIO there (2026-10-18).
      AppDelegate.registerAppPlugins(with: registry)
    }
    // BGAppRefreshTask: the OS grants ~30 s a few times a day at moments
    // it picks from usage; the plugin re-submits the next request with
    // this earliest-begin gap each time the task runs.
    WorkmanagerPlugin.registerPeriodicTask(
      withIdentifier: AppDelegate.photoBackfillIdentifier,
      frequency: NSNumber(value: 30 * 60))
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    AppDelegate.registerAppPlugins(with: engineBridge.pluginRegistry)
  }

  /// shared_preferences' name for Dart's 'background.native_launch_iso'
  /// (lib/ui/background_glue.dart backgroundNativeLaunchPrefsKey).
  static let backgroundLaunchDefaultsKey = "flutter.background.native_launch_iso"

  /// Records when workmanager created a background run's engine
  /// (2026-10-19). iOS's ~30 s grant is already running then, and the
  /// engine boot before Dart's first line comes out of it; the run counts
  /// its time budgets from this stamp (backgroundRunStart) instead of
  /// from its entry into Dart. UTC ISO 8601 with milliseconds, which
  /// Dart's DateTime.parse reads.
  static func stampBackgroundLaunch(
    _ defaults: UserDefaults = .standard, now: Date = Date()
  ) {
    let format = ISO8601DateFormatter()
    format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    defaults.set(format.string(from: now), forKey: backgroundLaunchDefaultsKey)
  }

  /// The plugins that live in this target (ImageIOPlugin.swift,
  /// BackgroundTimePlugin.swift), for every engine: the app's own and
  /// workmanager's headless background engine. Only the app's engine calls
  /// the background-time channel; registering it in both keeps one path.
  static func registerAppPlugins(with registry: FlutterPluginRegistry) {
    if let registrar = registry.registrar(forPlugin: "ImageIOPlugin") {
      ImageIOPlugin.register(with: registrar)
    }
    if let registrar = registry.registrar(forPlugin: "BackgroundTimePlugin") {
      BackgroundTimePlugin.register(with: registrar)
    }
  }
}
