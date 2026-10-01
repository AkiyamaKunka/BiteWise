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
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
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
  }
}
