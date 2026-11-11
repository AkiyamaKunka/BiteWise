import CryptoKit
import Foundation

/// The file layer of iCloud Backup (1.7.0), apart from iCloud itself: the
/// header reader, the owner rule, the coordinated write with its checks,
/// the previous-copy rotation and the coordinated delete. CloudBackupPlugin
/// hands it the container's Documents folder; RunnerTests hand it a
/// temporary folder (NSFileCoordinator works the same on local files).
///
/// The rules it keeps (design 2026-11-11, mirrored by Dart's
/// lib/services/backup/backup_format.dart):
/// - A header is the first 16 KB of a file, cut at the first `,"tables":`,
///   closed with `}`: format `calorie_tracker_export`, an integer version
///   of 2 or more, a known kind, a 32-hex install id and an integer seq.
///   Anything else is an unknown owner, and an unknown owner's file is
///   never replaced without the user's explicit Replace.
/// - `checkOwner` decides inside the coordinated access, never before it:
///   a file Dart looked at a moment ago may have been replaced by another
///   phone since.
/// - Before anything is replaced, the new file's size, SHA-256 and header
///   are checked against what Dart says it wrote.
/// - Each operation gets its own NSFileCoordinator(filePresenter: nil);
///   coordinators are never nested, and no file presenter is registered.
/// - Only codes and domains leave this layer, never error text or paths.
/// - It reads no timestamps or attributes of a file (no attributesOfItem,
///   no modification dates): the privacy manifest's C617.1 covers the app's
///   own containers only. Sizes are measured with FileHandle.seekToEnd.
final class CloudFiles {
  static let headerLimit = 16 * 1024
  static let maxFileBytes = 100 * 1024 * 1024
  static let picturesFolder = "Meal Pictures"
  static let kinds: Set<String> = ["records", "pictures", "full"]

  /// The folder backup paths are relative to.
  let root: URL

  init(root: URL) {
    self.root = root
  }

  // MARK: - paths

  /// `Chopstats Backup.json`, `Chopstats Backup (previous).json` or
  /// `Meal Pictures/2026-10.json`; nil for anything else (no `..`, no
  /// absolute paths, no other folders).
  func url(for path: String) -> URL? {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard path.hasSuffix(".json"), !path.hasPrefix("/"), !path.contains("..") else {
      return nil
    }
    if parts.count == 1, !parts[0].hasPrefix(".") {
      return root.appendingPathComponent(String(parts[0]), isDirectory: false)
    }
    if parts.count == 2, parts[0] == CloudFiles.picturesFolder, !parts[1].hasPrefix(".") {
      return root.appendingPathComponent(CloudFiles.picturesFolder, isDirectory: true)
        .appendingPathComponent(String(parts[1]), isDirectory: false)
    }
    return nil
  }

  // MARK: - header

  /// The envelope minus its tables, as a dictionary, when it is a valid
  /// backup header (see the type docs).
  static func parseHeader(_ prefix: Data) -> [String: Any]? {
    let data = prefix.count > headerLimit ? prefix.prefix(headerLimit) : prefix
    guard let marker = ",\"tables\":".data(using: .utf8),
      let cut = data.range(of: marker)
    else { return nil }
    var head = Data(data[data.startIndex..<cut.lowerBound])
    head.append(contentsOf: [UInt8(ascii: "}")])
    guard let object = try? JSONSerialization.jsonObject(with: head),
      let envelope = object as? [String: Any],
      envelope["format"] as? String == "calorie_tracker_export",
      let version = envelope["version"] as? NSNumber, isInteger(version),
      version.intValue >= 2,
      let backup = envelope["backup"] as? [String: Any],
      let kind = backup["kind"] as? String, kinds.contains(kind),
      let id = backup["install_id"] as? String, isInstallId(id),
      let seq = backup["seq"] as? NSNumber, isInteger(seq)
    else { return nil }
    return envelope
  }

  static func installId(of header: [String: Any]?) -> String? {
    (header?["backup"] as? [String: Any])?["install_id"] as? String
  }

  static func seq(of header: [String: Any]?) -> Int? {
    ((header?["backup"] as? [String: Any])?["seq"] as? NSNumber)?.intValue
  }

  /// JSON numbers arrive as NSNumber; a bool or a fraction is not a seq.
  private static func isInteger(_ n: NSNumber) -> Bool {
    if CFGetTypeID(n) == CFBooleanGetTypeID() { return false }
    return n.doubleValue == Double(n.intValue)
  }

  static func isInstallId(_ s: String) -> Bool {
    s.count == 32 && s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
  }

  /// The first 16 KB of [url].
  static func readPrefix(of url: URL) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    return try handle.read(upToCount: headerLimit) ?? Data()
  }

  /// The parsed header of [url], or nil when it is not a valid one.
  static func header(at url: URL) -> [String: Any]? {
    guard let data = try? readPrefix(of: url) else { return nil }
    return parseHeader(data)
  }

  // MARK: - the owner rule

  struct Expect {
    let installId: String
    /// nil = any seq of this install (pictures files, deletes).
    let seqs: [Int]?
    let adoptFrom: String?
    let allowAbsent: Bool
    let replaceUnknown: Bool

    init(
      installId: String, seqs: [Int]? = nil, adoptFrom: String? = nil,
      allowAbsent: Bool = false, replaceUnknown: Bool = false
    ) {
      self.installId = installId
      self.seqs = seqs
      self.adoptFrom = adoptFrom
      self.allowAbsent = allowAbsent
      self.replaceUnknown = replaceUnknown
    }

    /// WriteExpect.toMap() from Dart; nil when it names no valid install.
    init?(_ map: [String: Any]?) {
      guard let map = map, let id = map["installId"] as? String,
        CloudFiles.isInstallId(id)
      else { return nil }
      installId = id
      seqs = (map["seqs"] as? [NSNumber])?.map { $0.intValue }
      let adopt = map["adoptFrom"] as? String
      adoptFrom = adopt.flatMap { CloudFiles.isInstallId($0) ? $0 : nil }
      allowAbsent = map["allowAbsent"] as? Bool ?? false
      replaceUnknown = map["replaceUnknown"] as? Bool ?? false
    }

    /// Whether [id] is this install or the adopted one.
    func owns(_ id: String?) -> Bool {
      guard let id = id else { return false }
      return id == installId || id == adoptFrom
    }
  }

  enum Verdict: String {
    case allowed, ownedByOther, changedElsewhere, unknownOwner, absentNotAllowed
  }

  /// lib/services/backup/backup_format.dart checkOwner, the same rule.
  static func checkOwner(exists: Bool, header: [String: Any]?, expect: Expect) -> Verdict {
    if !exists { return expect.allowAbsent ? .allowed : .absentNotAllowed }
    guard let header = header, let id = installId(of: header), let seq = seq(of: header) else {
      return expect.replaceUnknown ? .allowed : .unknownOwner
    }
    if let adopt = expect.adoptFrom, id == adopt { return .allowed }
    if id == expect.installId {
      guard let seqs = expect.seqs else { return .allowed }
      return seqs.contains(seq) ? .allowed : .changedElsewhere
    }
    return .ownedByOther
  }

  // MARK: - item state

  /// Whether the item is there, downloaded or not. Before iOS 17 an
  /// evicted iCloud file is a hidden `.<name>.icloud` placeholder beside
  /// where the file would be.
  static func itemExists(_ url: URL) -> Bool {
    let fm = FileManager.default
    if fm.fileExists(atPath: url.path) { return true }
    let placeholder = url.deletingLastPathComponent()
      .appendingPathComponent(".\(url.lastPathComponent).icloud")
    return fm.fileExists(atPath: placeholder.path)
  }

  /// A local (not ubiquitous) file is always downloaded.
  static func isDownloaded(_ url: URL) -> Bool {
    var u = url
    u.removeAllCachedResourceValues()
    guard let values = try? u.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
      values.isUbiquitousItem == true
    else { return FileManager.default.fileExists(atPath: url.path) }
    return values.ubiquitousItemDownloadingStatus == .current
  }

  static func hasConflicts(_ url: URL) -> Bool {
    var u = url
    u.removeAllCachedResourceValues()
    let values = try? u.resourceValues(forKeys: [.ubiquitousItemHasUnresolvedConflictsKey])
    return values?.ubiquitousItemHasUnresolvedConflicts ?? false
  }

  // MARK: - verifying a file Dart wrote

  /// Size by seeking (no attribute read), SHA-256 streamed, header parsed
  /// and naming [installId].
  static func verify(source: URL, bytes: Int, sha256 hex: String, installId: String) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: source) else { return false }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd(), Int(size) == bytes, bytes <= maxFileBytes else {
      return false
    }
    do {
      try handle.seek(toOffset: 0)
    } catch {
      return false
    }
    var hasher = SHA256()
    var first = Data()
    while true {
      // read(upToCount:) gives nil (not an empty Data) at the end.
      let chunk: Data
      do {
        chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
      } catch {
        return false
      }
      if chunk.isEmpty { break }
      if first.count < headerLimit { first.append(chunk.prefix(headerLimit - first.count)) }
      hasher.update(data: chunk)
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    guard digest == hex.lowercased(), let header = parseHeader(first) else { return false }
    return CloudFiles.installId(of: header) == installId
  }

  // MARK: - write

  struct WriteRequest {
    let path: String
    let source: URL
    let bytes: Int
    let sha256: String
    let expect: Expect
    let keepPreviousPath: String?
    let allowDownload: Bool
  }

  enum Outcome {
    case ok(bytes: Int)
    case header([String: Any])
    case missing
    case deleted(Int)
    case verdict(Verdict, header: [String: Any]?)
    case notDownloaded
    case verifyFailed
    case twoCopies
    case timeout
    case badArguments
    case failure(NSError)
  }

  /// The body of a write, run INSIDE the coordinated access with the URLs
  /// the coordinator handed out.
  func performWrite(_ req: WriteRequest, dest: URL, previous: URL?) -> Outcome {
    let fm = FileManager.default
    let exists = CloudFiles.itemExists(dest)
    if exists && !CloudFiles.isDownloaded(dest) {
      if req.allowDownload { try? fm.startDownloadingUbiquitousItem(at: dest) }
      return .notDownloaded
    }
    let current = exists ? CloudFiles.header(at: dest) : nil
    let verdict = CloudFiles.checkOwner(exists: exists, header: current, expect: req.expect)
    if verdict != .allowed { return .verdict(verdict, header: current) }
    if exists, let outcome = settleConflicts(at: dest, expect: req.expect) { return outcome }
    guard
      CloudFiles.verify(
        source: req.source, bytes: req.bytes, sha256: req.sha256,
        installId: req.expect.installId)
    else { return .verifyFailed }
    do {
      if exists, let previous = previous {
        try rotatePrevious(from: dest, to: previous, expect: req.expect)
      }
      try place(req.source, at: dest, exists: exists)
      return .ok(bytes: req.bytes)
    } catch let error as NSError {
      return .failure(error)
    }
  }

  /// Unresolved versions of [dest] from this install are settled here;
  /// one from another install may be the only copy of that phone's data,
  /// so the write stops and Dart offers Combine.
  private func settleConflicts(at dest: URL, expect: Expect) -> Outcome? {
    guard CloudFiles.hasConflicts(dest),
      let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: dest),
      !versions.isEmpty
    else { return nil }
    if versions.contains(where: {
      !expect.owns(CloudFiles.installId(of: CloudFiles.header(at: $0.url)))
    }) {
      return .twoCopies
    }
    for v in versions { v.isResolved = true }
    try? NSFileVersion.removeOtherVersionsOfItem(at: dest)
    return nil
  }

  /// The file as it was before today's first write. Kept only when the
  /// previous copy is absent or this install's own: never over another
  /// install's file.
  private func rotatePrevious(from dest: URL, to previous: URL, expect: Expect) throws {
    let fm = FileManager.default
    let prevExists = CloudFiles.itemExists(previous)
    if prevExists {
      guard CloudFiles.isDownloaded(previous),
        expect.owns(CloudFiles.installId(of: CloudFiles.header(at: previous)))
      else { return }
    }
    let staging = try fm.url(
      for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: previous, create: true)
    defer { try? fm.removeItem(at: staging) }
    let copy = staging.appendingPathComponent(previous.lastPathComponent)
    try fm.copyItem(at: dest, to: copy)
    try place(copy, at: previous, exists: prevExists, move: true)
  }

  /// Copies (or moves) [source] into place through the replacement
  /// directory, so a reader never sees a half-written file.
  private func place(_ source: URL, at dest: URL, exists: Bool, move: Bool = false) throws {
    let fm = FileManager.default
    try fm.createDirectory(
      at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    let staging = try fm.url(
      for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: dest, create: true)
    defer { try? fm.removeItem(at: staging) }
    let staged = staging.appendingPathComponent(dest.lastPathComponent)
    if move {
      try fm.moveItem(at: source, to: staged)
    } else {
      try fm.copyItem(at: source, to: staged)
    }
    if exists && fm.fileExists(atPath: dest.path) {
      _ = try fm.replaceItemAt(dest, withItemAt: staged)
    } else {
      try fm.moveItem(at: staged, to: dest)
    }
  }

  /// The whole write: one asynchronous coordination over the file (and the
  /// previous copy when one is kept), on [queue]. [timeout] cancels the
  /// coordinator only while access has not been granted; once the accessor
  /// runs, its real result is what comes back. [completion] is called once.
  func write(
    _ req: WriteRequest, queue: OperationQueue, timeout: TimeInterval,
    completion: @escaping (Outcome) -> Void
  ) {
    guard let dest = url(for: req.path) else {
      completion(.badArguments)
      return
    }
    let previous = req.keepPreviousPath.flatMap { url(for: $0) }
    var intents = [NSFileAccessIntent.writingIntent(with: dest, options: .forReplacing)]
    if let previous = previous {
      intents.append(.writingIntent(with: previous, options: .forReplacing))
    }
    coordinate(intents, queue: queue, timeout: timeout, completion: completion) {
      self.performWrite(req, dest: intents[0].url, previous: intents.count > 1 ? intents[1].url : nil)
    }
  }

  // MARK: - delete

  /// The body of one delete, inside the coordinated access. A file not on
  /// this phone yet (dataless, or an `.icloud` placeholder before iOS 17)
  /// has no owner to read: its download is started, so a later delete (or
  /// a coordinated read, which waits for it) can tell, and it is left.
  func performDelete(at url: URL, expect: Expect) -> Outcome {
    guard CloudFiles.itemExists(url) else { return .deleted(0) }
    guard CloudFiles.isDownloaded(url) else {
      try? FileManager.default.startDownloadingUbiquitousItem(at: url)
      return .notDownloaded
    }
    let header = CloudFiles.header(at: url)
    let anySeq = Expect(installId: expect.installId, adoptFrom: expect.adoptFrom)
    let verdict = CloudFiles.checkOwner(exists: true, header: header, expect: anySeq)
    if verdict != .allowed { return .verdict(verdict, header: header) }
    do {
      try FileManager.default.removeItem(at: url)
      return .deleted(1)
    } catch let error as NSError {
      return .failure(error)
    }
  }

  func delete(
    _ path: String, expect: Expect, queue: OperationQueue, timeout: TimeInterval,
    completion: @escaping (Outcome) -> Void
  ) {
    guard let target = url(for: path) else {
      completion(.badArguments)
      return
    }
    let intent = NSFileAccessIntent.writingIntent(with: target, options: .forDeleting)
    coordinate([intent], queue: queue, timeout: timeout, completion: completion) {
      self.performDelete(at: intent.url, expect: expect)
    }
  }

  /// Deletes [paths] one after another, each in its own coordinated
  /// delete, and answers once with the channel reply. A file that is not
  /// this install's (or the adopted one's) is refused and counted. One
  /// that is not on this phone yet (its download is started) or whose
  /// coordination timed out is left and counted, and the rest go on: one
  /// evicted month never keeps the others, or the records file after it.
  /// Any other error stops the rest, which count as left.
  func deleteAll(
    _ paths: [String], expect: Expect, queue: OperationQueue, timeout: TimeInterval,
    protectedDataAvailable: Bool, completion: @escaping ([String: Any]) -> Void
  ) {
    var deleted = 0
    var refused = 0
    var left = 0
    // Each step starts only after the one before it answered: the counts
    // are never touched from two threads at once.
    func next(_ i: Int) {
      guard i < paths.count else {
        removeEmptyPicturesFolder()
        completion(["status": "ok", "deleted": deleted, "refused": refused, "left": left])
        return
      }
      delete(paths[i], expect: expect, queue: queue, timeout: timeout) { outcome in
        switch outcome {
        case .deleted(let n):
          deleted += n
          next(i + 1)
        case .verdict:
          refused += 1
          next(i + 1)
        case .notDownloaded, .timeout:
          left += 1
          next(i + 1)
        default:
          var r = CloudFiles.reply(outcome, protectedDataAvailable: protectedDataAvailable)
          r["deleted"] = deleted
          r["refused"] = refused
          r["left"] = left + paths.count - i
          completion(r)
        }
      }
    }
    next(0)
  }

  /// Removes `Meal Pictures` once nothing is left in it.
  func removeEmptyPicturesFolder() {
    let folder = root.appendingPathComponent(CloudFiles.picturesFolder, isDirectory: true)
    let fm = FileManager.default
    guard let left = try? fm.contentsOfDirectory(atPath: folder.path), left.isEmpty else { return }
    let intent = NSFileAccessIntent.writingIntent(with: folder, options: .forDeleting)
    NSFileCoordinator(filePresenter: nil).coordinate(with: [intent], queue: OperationQueue()) { error in
      guard error == nil else { return }
      try? fm.removeItem(at: intent.url)
    }
  }

  // MARK: - read

  /// A coordinated read of [path]: [body] gets the URL to read.
  func read(
    _ path: String, queue: OperationQueue, timeout: TimeInterval,
    completion: @escaping (Outcome) -> Void, body: @escaping (URL) -> Outcome
  ) {
    guard let target = url(for: path) else {
      completion(.badArguments)
      return
    }
    let intent = NSFileAccessIntent.readingIntent(with: target, options: [])
    coordinate([intent], queue: queue, timeout: timeout, completion: completion) {
      body(intent.url)
    }
  }

  // MARK: - coordination with a timeout

  private func coordinate(
    _ intents: [NSFileAccessIntent], queue: OperationQueue, timeout: TimeInterval,
    completion: @escaping (Outcome) -> Void, accessor: @escaping () -> Outcome
  ) {
    let coordinator = NSFileCoordinator(filePresenter: nil)
    let state = CoordinationState()
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
      if state.timeOutIfNotStarted() {
        coordinator.cancel()
        completion(.timeout)
      }
    }
    coordinator.coordinate(with: intents, queue: queue) { error in
      guard state.startIfNotTimedOut() else { return }
      if let error = error as NSError? {
        completion(.failure(error))
        return
      }
      completion(accessor())
    }
  }

  /// Which came first: the access or the timeout.
  private final class CoordinationState {
    private let lock = NSLock()
    private var started = false
    private var timedOut = false

    func startIfNotTimedOut() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      if timedOut { return false }
      started = true
      return true
    }

    func timeOutIfNotStarted() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      if started { return false }
      timedOut = true
      return true
    }
  }

  // MARK: - errors

  /// Codes only: never the message or a path. 4353
  /// (NSUbiquitousFileUnavailableError) is about one file: another device
  /// has not uploaded it yet, or it cannot be fetched now. It is answered
  /// as notDownloaded, which Dart treats as "later", never as
  /// `unavailable`, which means the container itself is missing (no
  /// entitlement, iCloud Drive off for the app).
  static func errorReply(_ error: NSError, protectedDataAvailable: Bool) -> [String: Any] {
    if error.domain == NSCocoaErrorDomain {
      switch error.code {
      case 4354: return ["status": "quota"]
      case 4355: return ["status": "serverUnavailable"]
      case 4353: return ["status": "notDownloaded"]
      case 640: return ["status": "diskFull"]
      // A `where` binds only the pattern it follows: one per code.
      case 513 where !protectedDataAvailable, 257 where !protectedDataAvailable:
        return ["status": "locked"]
      case NSUserCancelledError: return ["status": "timeout"]
      default: break
      }
    }
    if error.domain == NSPOSIXErrorDomain && error.code == Int(EPERM) && !protectedDataAvailable {
      return ["status": "locked"]
    }
    return ["status": "error", "domain": error.domain, "code": error.code]
  }

  /// The channel reply for [outcome].
  static func reply(_ outcome: Outcome, protectedDataAvailable: Bool) -> [String: Any] {
    switch outcome {
    case .ok(let bytes): return ["status": "ok", "bytes": bytes]
    case .header(let h): return ["status": "ok", "header": h]
    case .missing: return ["status": "missing"]
    case .deleted(let n): return ["status": "ok", "deleted": n]
    case .verdict(let v, let header):
      var r: [String: Any] = ["status": v.rawValue]
      if let header = header { r["header"] = header }
      return r
    case .notDownloaded: return ["status": "notDownloaded"]
    case .verifyFailed: return ["status": "verifyFailed"]
    case .twoCopies: return ["status": "twoCopies"]
    case .timeout: return ["status": "timeout"]
    case .badArguments: return ["status": "badArguments"]
    case .failure(let e): return errorReply(e, protectedDataAvailable: protectedDataAvailable)
    }
  }
}
