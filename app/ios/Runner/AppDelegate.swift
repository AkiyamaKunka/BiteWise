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
    // The backup-excluded local store (lib/services/local_store.dart):
    // made and flagged at every launch, before either engine can write.
    AppDelegate.prepareLocalStore()
    // The background run gets its own Flutter engine; it needs the same
    // plugins (photo library, database, notifications, HTTP) registered.
    // workmanager calls this right after it creates and starts that engine,
    // before Dart's task runs: the earliest moment the run's clock can
    // start from here.
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

  /// Records when workmanager started a background run's engine
  /// (2026-10-19), right after creating it (workmanager_apple
  /// BackgroundWorker.performBackgroundRequest: FlutterEngine(...), run,
  /// then this callback). iOS's ~30 s grant is already running then —
  /// the process launch and the shell's creation came out of it uncounted
  /// — and the rest of the boot before Dart's task does too; the run counts
  /// its time budgets from this stamp (backgroundRunStart) instead of
  /// from its entry into Dart. The stamp still lands before that run's
  /// Dart reads it: executeTask is sent after this callback. UTC ISO 8601
  /// with milliseconds, which Dart's DateTime.parse reads.
  static func stampBackgroundLaunch(
    _ defaults: UserDefaults = .standard, now: Date = Date()
  ) {
    let format = ISO8601DateFormatter()
    format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    defaults.set(format.string(from: now), forKey: backgroundLaunchDefaultsKey)
  }

  /// MUST equal localStoreDirName (lib/services/local_store.dart).
  static let localStoreDirectoryName = "bitewise_local"

  /// Creates Application Support/bitewise_local and excludes it from iCloud
  /// and computer backups (design F1, 2026-10-23). The flag on the
  /// directory covers every document Dart writes inside it, so state that
  /// hints at location or is only valid on this device (the photo library's
  /// change token) is never restored onto another phone. Dart never creates
  /// the directory on iOS — one it made would be backed up until a launch
  /// flagged it — so this runs first thing at every launch: idempotent, and
  /// it re-applies the flag whatever a restore or an earlier failed launch
  /// left. Never throws; nil when the directory could not be prepared, and
  /// Dart's store then reads {} and refuses writes.
  @discardableResult
  static func prepareLocalStore(
    in support: URL? = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first
  ) -> URL? {
    guard let support = support else { return nil }
    var directory = support.appendingPathComponent(
      localStoreDirectoryName, isDirectory: true)
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try directory.setResourceValues(values)
      return directory
    } catch {
      return nil
    }
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
