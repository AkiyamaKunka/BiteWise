import Flutter
import UIKit

/// A little more time for a photo already being analyzed when the user
/// leaves the app.
///
/// WHY THIS EXISTS (2026-10-19): iOS suspends an app a few seconds after it
/// leaves the foreground. A quick "did it log?" open starts the launch
/// catch-up, the user goes back to the home screen, and the photo in flight
/// is frozen mid-upload or mid-save: the server answered (Oct 14 01:59) but
/// the meal was never written, or the photo stayed reserved and was never
/// sent (Oct 18 14:11). A background task asks iOS to finish that one
/// photo first.
///
/// Channel `dev.calorietracker/bgtime`:
///   begin {name: String} → Int? (a token for the task; nil when iOS refuses)
///   end   {id: Int}      → nil
/// The Dart side (lib/services/photo/background_time.dart) holds ONE task
/// per photo and always ends it. The expiration handler ends the task too:
/// a task still open when the time runs out gets the app killed. Tokens
/// this plugin did not hand out, or already ended, are ignored, so an end
/// can never be doubled.
///
/// Only the app's own engine calls it (the photo pipeline built in
/// lib/ui/di.dart). The headless background engine has its own grant from
/// BGTaskScheduler and never asks for one.
final class BackgroundTimePlugin: NSObject, FlutterPlugin {
  static let channelName = "dev.calorietracker/bgtime"

  /// One task's identifier, shared by the plugin and the task's expiration
  /// handler: the handler can end the task through it even when the plugin
  /// is gone by then (its engine destroyed), and whoever ends it first
  /// marks it ended, so it is never ended twice.
  private final class OpenTask {
    var id: UIBackgroundTaskIdentifier = .invalid
    func end() {
      guard id != .invalid else { return }
      UIApplication.shared.endBackgroundTask(id)
      id = .invalid
    }
  }

  /// Open tasks by the token handed to Dart. Touched only on the main
  /// thread: channel calls and expiration handlers both arrive there.
  private var open: [Int: OpenTask] = [:]
  private var lastToken = 0

  /// How many tasks are open (RunnerTests).
  var openTaskCount: Int { open.count }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(BackgroundTimePlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "begin":
      let name = args?["name"] as? String ?? "photo"
      lastToken += 1
      let token = lastToken
      let task = OpenTask()
      // The handler runs later on the main thread (never inside this call),
      // so the task is in `open` by the time it can fire. Without the
      // plugin it still ends the task: one left open gets the app killed.
      task.id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
        self?.end(token)
        task.end()
      }
      if task.id == .invalid {
        result(nil)
        return
      }
      open[token] = task
      result(token)
    case "end":
      if let token = (args?["id"] as? NSNumber)?.intValue {
        end(token)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func end(_ token: Int) {
    open.removeValue(forKey: token)?.end()
  }
}
