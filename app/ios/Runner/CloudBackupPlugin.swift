import CryptoKit
import Flutter
import Foundation
import UIKit
import UniformTypeIdentifiers

/// iCloud Backup (1.7.0): the user's meal record in their OWN iCloud Drive,
/// in a Chopstats folder they can see in the Files app. No account, and
/// neither the developer nor any server holds the data (owner decisions
/// 2026-11-10).
///
/// Channel `dev.calorietracker/cloudbackup` (Dart side:
/// lib/services/backup/cloud_backup_channel.dart). Every reply is a map
/// with a `status`; errors carry a domain and a code, never text or paths.
///
///   status                 → {status: ok|noAccount|unavailable, accountChanged}
///   deviceKey              → {status: ok, key: hex | null}
///   startWatching / stopWatching → {status}
///   list                   → {status, gathered, liveMs, items: [...]}
///   itemState {path}       → {status, exists: yes|no|unknown, downloading, hasConflicts}
///   readHeader {path, allowDownload, timeoutMs} → ok{header} | missing |
///                            notDownloaded | unknownOwner | timeout | …
///   fetch {path, destPath, timeoutMs} → ok{bytes} | missing | tooBig | …
///   startDownloads {paths} → {status}
///   write {path, sourcePath, bytes, sha256, expect, keepPreviousPath?,
///          allowDownload, timeoutMs} → ok{bytes} | ownedByOther{header} |
///          changedElsewhere{header} | unknownOwner | absentNotAllowed |
///          notDownloaded | verifyFailed | twoCopies | timeout | …
///   delete {paths, expect, timeoutMs} → ok{deleted, refused, left} |
///          error{deleted, refused, left} | … (CloudFiles.deleteAll)
///   conflicts {path, destDir} → {status, versions: [{tmpPath, header?}]}
///   resolveConflicts {path, installIds, timeoutMs} → ok{left} | timeout | …
///   pickFiles              → ok{paths} | cancelled | unavailable
///   backgroundTimeRemaining → {status, ms: Int | null}
///
/// Threads: the identity token, identifierForVendor, UIApplication and the
/// protected-data state are read on main. The container URL is fetched on
/// `statusQueue` (it can block), at every `status` call. File work runs on
/// `fileQueue`, one operation at a time. Replies go back on main, once.
///
/// Registered for both engines (AppDelegate.registerAppPlugins): the
/// headless background run may update a backup this install already owns
/// (never a first write, never a download, never a question). The metadata
/// query and the picker belong to the app's engine only.
///
/// The container exists only once Runner.entitlements names it (docs/
/// RELEASING.md § iCloud container). Without the entitlement the container
/// URL is nil and every call reports `unavailable`.
final class CloudBackupPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
  static let channelName = "dev.calorietracker/cloudbackup"

  /// MUST equal kICloudContainerId (lib/services/backup/backup_format.dart)
  /// and, once switched on, Runner.entitlements and Info.plist
  /// NSUbiquitousContainers (backup_container_pin_test.dart).
  static let containerIdentifier = "iCloud.dev.calorietracker.calorieTracker"

  /// This plugin's own UserDefaults key (not under Flutter's `flutter.`
  /// prefix): the archived iCloud identity token of the last status call.
  static let accountTokenKey = "cloudbackup.account_token"

  /// Mixed into identifierForVendor before hashing: the key is only ever
  /// compared with itself on this phone.
  static let deviceKeySalt = "chopstats.backup.device.v1"

  private let statusQueue = DispatchQueue(label: "dev.calorietracker.cloudbackup.status")
  private let fileQueue: OperationQueue = {
    let q = OperationQueue()
    q.name = "dev.calorietracker.cloudbackup.files"
    q.maxConcurrentOperationCount = 1
    return q
  }()

  /// Main-thread state.
  private var protectedDataAvailable = true
  private var picker: UIDocumentPickerViewController?
  private var pickerReply: ((Any?) -> Void)?

  /// The container's Documents folder, last fetched on statusQueue.
  private let lock = NSLock()
  private var documents: URL?

  // The metadata query: created and stopped on main, its notifications
  // and reads on its own queue; the snapshot is read under `lock`.
  private var query: NSMetadataQuery?
  private let queryQueue: OperationQueue = {
    let q = OperationQueue()
    q.name = "dev.calorietracker.cloudbackup.query"
    q.maxConcurrentOperationCount = 1
    return q
  }()
  private var snapshot: [[String: Any]] = []
  private var gatheredAt: Date?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
    let plugin = CloudBackupPlugin()
    registrar.addMethodCallDelegate(plugin, channel: channel)
    plugin.observeProtectedData()
  }

  private func observeProtectedData() {
    let center = NotificationCenter.default
    center.addObserver(
      self, selector: #selector(protectedDataWillGo),
      name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
    center.addObserver(
      self, selector: #selector(protectedDataCame),
      name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
    DispatchQueue.main.async {
      self.protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
    }
  }

  @objc private func protectedDataWillGo() {
    protectedDataAvailable = false
  }

  @objc private func protectedDataCame() {
    protectedDataAvailable = true
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - dispatch

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let reply = CloudBackupPlugin.once(result)
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "status": status(reply)
    case "deviceKey":
      let key: Any = CloudBackupPlugin.deviceKey() ?? NSNull()
      reply(["status": "ok", "key": key])
    case "startWatching": startWatching(reply)
    case "stopWatching": stopWatching(reply)
    case "list": reply(listSnapshot())
    case "itemState": withFiles(reply) { files in self.itemState(files, args, reply) }
    case "readHeader": readHeader(args, reply)
    case "fetch": fetch(args, reply)
    case "startDownloads": withFiles(reply) { files in self.startDownloads(files, args, reply) }
    case "write": write(args, reply)
    case "delete": delete(args, reply)
    case "conflicts": withFiles(reply) { files in self.conflicts(files, args, reply) }
    case "resolveConflicts": withFiles(reply) { files in self.resolveConflicts(files, args, reply) }
    case "pickFiles": pickFiles(reply)
    case "backgroundTimeRemaining":
      let left = UIApplication.shared.backgroundTimeRemaining
      // DBL_MAX in the foreground: no limit, so no number.
      let ms: Any = left > 24 * 3600 ? NSNull() : Int(left * 1000)
      reply(["status": "ok", "ms": ms])
    default: result(FlutterMethodNotImplemented)
    }
  }

  /// A reply that goes back on main, once.
  private static func once(_ result: @escaping FlutterResult) -> (Any?) -> Void {
    let lock = NSLock()
    var sent = false
    return { value in
      lock.lock()
      let first = !sent
      sent = true
      lock.unlock()
      guard first else { return }
      if Thread.isMainThread {
        result(value)
      } else {
        DispatchQueue.main.async { result(value) }
      }
    }
  }

  private func timeout(_ args: [String: Any], default seconds: TimeInterval = 20) -> TimeInterval {
    guard let ms = (args["timeoutMs"] as? NSNumber)?.doubleValue, ms > 0 else { return seconds }
    return min(ms / 1000, 60)
  }

  // MARK: - account and container

  private func status(_ reply: @escaping (Any?) -> Void) {
    // main: the token, and whether it changed since the last call.
    guard let token = FileManager.default.ubiquityIdentityToken else {
      reply(["status": "noAccount", "accountChanged": false])
      return
    }
    let changed = CloudBackupPlugin.noteToken(token)
    statusQueue.async {
      let container = FileManager.default.url(
        forUbiquityContainerIdentifier: CloudBackupPlugin.containerIdentifier)
      let docs = container?.appendingPathComponent("Documents", isDirectory: true)
      self.lock.lock()
      self.documents = docs
      self.lock.unlock()
      reply(["status": docs == nil ? "unavailable" : "ok", "accountChanged": changed])
    }
  }

  /// Stores [token] and says whether it differs from the stored one,
  /// compared with isEqual (never the archive bytes).
  static func noteToken(_ token: NSCoding & NSCopying & NSObjectProtocol, defaults: UserDefaults = .standard) -> Bool {
    guard let archived = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false) else {
      return false
    }
    var changed = false
    if let stored = defaults.data(forKey: accountTokenKey),
      let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: stored)
    {
      unarchiver.requiresSecureCoding = false
      let old = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSObjectProtocol
      unarchiver.finishDecoding()
      changed = !(old?.isEqual(token) ?? false)
    }
    defaults.set(archived, forKey: accountTokenKey)
    return changed
  }

  /// SHA-256 of the salt and identifierForVendor; nil while iOS has none
  /// (right after a restart before the first unlock), and the run is then
  /// skipped, never read as "another phone".
  static func deviceKey() -> String? {
    guard let vendor = UIDevice.current.identifierForVendor?.uuidString else { return nil }
    let digest = SHA256.hash(data: Data("\(deviceKeySalt):\(vendor)".utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  /// [body] with the file layer over the container's Documents folder,
  /// fetched again on statusQueue when no status call has yet.
  private func withFiles(_ reply: @escaping (Any?) -> Void, _ body: @escaping (CloudFiles) -> Void) {
    lock.lock()
    let known = documents
    lock.unlock()
    if let docs = known {
      body(CloudFiles(root: docs))
      return
    }
    statusQueue.async {
      let docs = FileManager.default.url(
        forUbiquityContainerIdentifier: CloudBackupPlugin.containerIdentifier)?
        .appendingPathComponent("Documents", isDirectory: true)
      self.lock.lock()
      self.documents = docs
      self.lock.unlock()
      guard let docs = docs else {
        reply(["status": "unavailable"])
        return
      }
      body(CloudFiles(root: docs))
    }
  }

  private var protectedNow: Bool {
    // Read on main when called from main; elsewhere the last value seen.
    protectedDataAvailable
  }

  // MARK: - the metadata query

  private func startWatching(_ reply: @escaping (Any?) -> Void) {
    if query != nil {
      reply(["status": "ok"])
      return
    }
    let q = NSMetadataQuery()
    q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
    q.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "*.json")
    q.operationQueue = queryQueue
    let center = NotificationCenter.default
    center.addObserver(
      self, selector: #selector(queryChanged(_:)),
      name: .NSMetadataQueryDidFinishGathering, object: q)
    center.addObserver(
      self, selector: #selector(queryChanged(_:)), name: .NSMetadataQueryDidUpdate, object: q)
    query = q
    lock.lock()
    snapshot = []
    gatheredAt = nil
    lock.unlock()
    queryQueue.addOperation {
      q.start()
    }
    reply(["status": "ok"])
  }

  private func stopWatching(_ reply: @escaping (Any?) -> Void) {
    if let q = query {
      NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: q)
      NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: q)
      queryQueue.addOperation {
        q.stop()
      }
    }
    query = nil
    lock.lock()
    snapshot = []
    gatheredAt = nil
    lock.unlock()
    reply(["status": "ok"])
  }

  /// On queryQueue (the query's operationQueue).
  @objc private func queryChanged(_ note: Notification) {
    guard let q = note.object as? NSMetadataQuery else { return }
    q.disableUpdates()
    var items: [[String: Any]] = []
    for i in 0..<q.resultCount {
      guard let item = q.result(at: i) as? NSMetadataItem,
        let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
        let path = CloudBackupPlugin.relativePath(url)
      else { continue }
      let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
      var entry: [String: Any] = [
        "path": path,
        "downloading": status != NSMetadataUbiquitousItemDownloadingStatusCurrent,
        "uploaded": (item.value(forAttribute: NSMetadataUbiquitousItemIsUploadedKey) as? NSNumber)?.boolValue ?? false,
        "uploading": (item.value(forAttribute: NSMetadataUbiquitousItemIsUploadingKey) as? NSNumber)?.boolValue ?? false,
        "hasConflicts": (item.value(forAttribute: NSMetadataUbiquitousItemHasUnresolvedConflictsKey) as? NSNumber)?.boolValue ?? false,
      ]
      if let e = item.value(forAttribute: NSMetadataUbiquitousItemUploadingErrorKey) as? NSError {
        entry["uploadError"] = CloudFiles.errorReply(e, protectedDataAvailable: true)["status"]
        entry["uploadErrorCode"] = e.code
      }
      if let e = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingErrorKey) as? NSError {
        entry["downloadError"] = CloudFiles.errorReply(e, protectedDataAvailable: true)["status"]
      }
      items.append(entry)
    }
    q.enableUpdates()
    lock.lock()
    snapshot = items
    if note.name == .NSMetadataQueryDidFinishGathering || gatheredAt == nil {
      gatheredAt = gatheredAt ?? Date()
    }
    lock.unlock()
  }

  /// `Chopstats Backup.json` or `Meal Pictures/2026-10.json` from a
  /// metadata URL; nil for anything deeper or elsewhere.
  static func relativePath(_ url: URL) -> String? {
    let name = url.lastPathComponent
    let parent = url.deletingLastPathComponent().lastPathComponent
    if parent == CloudFiles.picturesFolder,
      url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Documents"
    {
      return "\(CloudFiles.picturesFolder)/\(name)"
    }
    if parent == "Documents" { return name }
    return nil
  }

  private func listSnapshot() -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    let live = gatheredAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
    return [
      "status": query == nil ? "notWatching" : "ok",
      "gathered": gatheredAt != nil,
      "liveMs": live,
      "items": snapshot,
    ]
  }

  // MARK: - files

  private func itemState(_ files: CloudFiles, _ args: [String: Any], _ reply: @escaping (Any?) -> Void) {
    guard let path = args["path"] as? String, let url = files.url(for: path) else {
      reply(["status": "badArguments"])
      return
    }
    fileQueue.addOperation {
      let exists = CloudFiles.itemExists(url)
      reply([
        "status": "ok",
        "exists": exists ? "yes" : "no",
        "downloading": exists && !CloudFiles.isDownloaded(url),
        "hasConflicts": exists && CloudFiles.hasConflicts(url),
      ])
    }
  }

  private func readHeader(_ args: [String: Any], _ reply: @escaping (Any?) -> Void) {
    withFiles(reply) { files in
      guard let path = args["path"] as? String, let url = files.url(for: path) else {
        reply(["status": "badArguments"])
        return
      }
      let allowDownload = args["allowDownload"] as? Bool ?? false
      let protected = self.protectedNow
      self.fileQueue.addOperation {
        guard CloudFiles.itemExists(url) else {
          reply(["status": "missing"])
          return
        }
        if !CloudFiles.isDownloaded(url) {
          guard allowDownload else {
            reply(["status": "notDownloaded"])
            return
          }
          try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        files.read(path, queue: self.fileQueue, timeout: self.timeout(args)) { outcome in
          reply(CloudFiles.reply(outcome, protectedDataAvailable: protected))
        } body: { readURL in
          do {
            let prefix = try CloudFiles.readPrefix(of: readURL)
            guard let header = CloudFiles.parseHeader(prefix) else {
              return .verdict(.unknownOwner, header: nil)
            }
            return .header(header)
          } catch let error as NSError {
            return .failure(error)
          }
        }
      }
    }
  }

  private func fetch(_ args: [String: Any], _ reply: @escaping (Any?) -> Void) {
    withFiles(reply) { files in
      guard let path = args["path"] as? String, files.url(for: path) != nil,
        let destPath = args["destPath"] as? String
      else {
        reply(["status": "badArguments"])
        return
      }
      let dest = URL(fileURLWithPath: destPath)
      let protected = self.protectedNow
      files.read(path, queue: self.fileQueue, timeout: self.timeout(args, default: 60)) { outcome in
        reply(CloudFiles.reply(outcome, protectedDataAvailable: protected))
      } body: { readURL in
        let fm = FileManager.default
        guard fm.fileExists(atPath: readURL.path) else { return .missing }
        do {
          let handle = try FileHandle(forReadingFrom: readURL)
          let size = Int(try handle.seekToEnd())
          try? handle.close()
          if size > CloudFiles.maxFileBytes { return .verifyFailed }
          try? fm.removeItem(at: dest)
          try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
          try fm.copyItem(at: readURL, to: dest)
          return .ok(bytes: size)
        } catch let error as NSError {
          return .failure(error)
        }
      }
    }
  }

  private func startDownloads(_ files: CloudFiles, _ args: [String: Any], _ reply: @escaping (Any?) -> Void) {
    let urls = (args["paths"] as? [String] ?? []).compactMap { files.url(for: $0) }
    fileQueue.addOperation {
      for url in urls where !CloudFiles.isDownloaded(url) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
      }
      reply(["status": "ok"])
    }
  }

  private func write(_ args: [String: Any], _ reply: @escaping (Any?) -> Void) {
    withFiles(reply) { files in
      guard let path = args["path"] as? String,
        let source = args["sourcePath"] as? String,
        let bytes = (args["bytes"] as? NSNumber)?.intValue,
        let sha = args["sha256"] as? String,
        let expect = CloudFiles.Expect(args["expect"] as? [String: Any])
      else {
        reply(["status": "badArguments"])
        return
      }
      let req = CloudFiles.WriteRequest(
        path: path, source: URL(fileURLWithPath: source), bytes: bytes, sha256: sha,
        expect: expect, keepPreviousPath: args["keepPreviousPath"] as? String,
        allowDownload: args["allowDownload"] as? Bool ?? false)
      let protected = self.protectedNow
      files.write(req, queue: self.fileQueue, timeout: self.timeout(args)) { outcome in
        reply(CloudFiles.reply(outcome, protectedDataAvailable: protected))
      }
    }
  }

  private func delete(_ args: [String: Any], _ reply: @escaping (Any?) -> Void) {
    withFiles(reply) { files in
      guard let paths = args["paths"] as? [String],
        let expect = CloudFiles.Expect(args["expect"] as? [String: Any])
      else {
        reply(["status": "badArguments"])
        return
      }
      files.deleteAll(
        paths, expect: expect, queue: self.fileQueue, timeout: self.timeout(args),
        protectedDataAvailable: self.protectedNow
      ) { r in
        reply(r)
      }
    }
  }

  /// Copies each unresolved version of [path] to destDir, with its parsed
  /// header (nil when it has none), inside one coordinated read.
  private func conflicts(_ files: CloudFiles, _ args: [String: Any], _ reply: @escaping (Any?) -> Void) {
    guard let path = args["path"] as? String, let destDir = args["destDir"] as? String else {
      reply(["status": "badArguments"])
      return
    }
    let dir = URL(fileURLWithPath: destDir, isDirectory: true)
    var versions: [[String: Any]] = []
    let protected = protectedNow
    files.read(path, queue: fileQueue, timeout: timeout(args)) { outcome in
      if case .deleted = outcome {
        reply(["status": "ok", "versions": versions])
      } else {
        reply(CloudFiles.reply(outcome, protectedDataAvailable: protected))
      }
    } body: { url in
      let fm = FileManager.default
      do {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let found = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        for (i, v) in found.enumerated() {
          let copy = dir.appendingPathComponent("conflict-\(i).json")
          try? fm.removeItem(at: copy)
          try fm.copyItem(at: v.url, to: copy)
          var entry: [String: Any] = ["tmpPath": copy.path]
          if let h = CloudFiles.header(at: copy) { entry["header"] = h }
          versions.append(entry)
        }
        return .deleted(found.count)
      } catch let error as NSError {
        return .failure(error)
      }
    }
  }

  /// CloudFiles.resolveConflicts, with the call's timeout.
  private func resolveConflicts(_ files: CloudFiles, _ args: [String: Any], _ reply: @escaping (Any?) -> Void) {
    guard let path = args["path"] as? String, let ids = args["installIds"] as? [String] else {
      reply(["status": "badArguments"])
      return
    }
    let protected = protectedNow
    files.resolveConflicts(path, installIds: ids, queue: fileQueue, timeout: timeout(args)) { outcome in
      reply(CloudFiles.reply(outcome, protectedDataAvailable: protected))
    }
  }

  // MARK: - the document picker (app engine only)

  private func pickFiles(_ reply: @escaping (Any?) -> Void) {
    guard pickerReply == nil else {
      reply(["status": "busy"])
      return
    }
    guard let presenter = CloudBackupPlugin.topViewController() else {
      reply(["status": "unavailable"])
      return
    }
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true)
    picker.allowsMultipleSelection = true
    picker.delegate = self
    self.picker = picker
    pickerReply = reply
    presenter.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    finishPicking(["status": "ok", "paths": urls.map { $0.path }])
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finishPicking(["status": "cancelled"])
  }

  private func finishPicking(_ value: [String: Any]) {
    let reply = pickerReply
    pickerReply = nil
    picker = nil
    reply?(value)
  }

  /// The foreground-active scene's key window, and the controller on top
  /// of whatever it presents.
  private static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
    var top = window?.rootViewController
    while let presented = top?.presentedViewController, !presented.isBeingDismissed {
      top = presented
    }
    return top
  }
}
