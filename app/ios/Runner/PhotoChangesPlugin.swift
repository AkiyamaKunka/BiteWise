import CryptoKit
import Flutter
import Foundation
import Photos
import UIKit

/// The photo library's persistent change history: which photos were ADDED
/// since a saved point, whatever date they carry (design G1a, 2026-10-23).
///
/// WHY THIS EXISTS: the automatic scan finds new photos by creation date
/// (lib/services/photo/watcher.dart). A photo another app imports late —
/// the Meta AI app copying glasses photos in hours after they were taken,
/// AirDrop, WeChat, an iCloud download — keeps its capture time as its
/// creationDate, so a "created after the last scan" query never sees it
/// (simulator probe 2026-10-23: a HEIC whose EXIF said three days ago was
/// missing from creationDate > cutoff and present in the change history).
/// PHPhotoLibrary.fetchPersistentChanges(since:) (iOS 16+) reports every
/// insert since a token, from any app, across launches.
///
/// Channel `dev.calorietracker/photochanges` (Dart side:
/// lib/services/photo/photo_changes.dart):
///   currentToken → {status: ok|unsupported|denied|error, token?, device_tag?,
///                   error_code?}
///   insertedImagesSince {token?, limit, budget_ms, max_changes} →
///     {status: ok|fresh|expired|unavailable|error|unsupported|denied,
///      error_code?, token?, ids: [{id, created_ms?, added_ms?}], truncated,
///      dropped?, device_tag?}
///   albumAssetIds {titles, sinceMs, limit} → {status: ok|denied|error,
///                                             ids, error_code?}
///   assetDates {ids} → {status: ok|denied, ids: [{id, created_ms?,
///                       added_ms?}]}
///
/// - token: base64 of the PHPersistentChangeToken archived with secure
///   coding. In a reply it is always the token to store next: the one the
///   caller sent when nothing moved or on an error, the last processed
///   change's when changes were read, the library's current one for fresh,
///   expired and unavailable.
/// - device_tag: 8 hex characters of SHA-256(identifierForVendor), so a
///   token can be tied to the phone (and app install) that produced it. A
///   token restored onto another phone points into a different library.
/// - fresh: no token was sent; here is the current one, nothing to report.
///   expired (PHPhotosError 3105) and unavailable (3210, or a token that
///   cannot be unarchived) mean history since the token is gone: store the
///   new token and rescan by date. Any other failure is error and changes
///   nothing; retry later with the same token.
/// - Only inserted image assets that are not hidden, newest first by
///   creationDate, at most `limit`; `dropped` (ok only) counts the older
///   ones past it, which the returned token has moved past as well — an
///   iCloud burst is capped, and the caller may rescan by date. Updates
///   and deletions are ignored: an insert produces a burst of updates
///   (probe: 1 insert, 7 updates) and one new album dozens of collection
///   updates.
/// - Reading history is bounded: it stops after budget_ms (≤ 1.5 s) or
///   max_changes (≤ 5,000) changes and answers truncated=true with the
///   token of the LAST PROCESSED change, so the next call resumes there.
///   A week-old token cannot eat the ~30 s background grant.
/// - assetDates (design G2b): the creation and added dates of up to 50
///   image assets by identifier, for a glasses photo whose creation date
///   may only be its import time. Ones that are gone, hidden or not images
///   are left out. Needs no history: iOS 15 answers too, without added_ms.
///
/// Read-only on PhotoKit: no change requests, and it never asks for
/// authorization — without access it answers denied. All PhotoKit work
/// runs on a utility queue; replies arrive on the platform thread; nothing
/// is thrown across the channel.
///
/// Registered for BOTH engines (AppDelegate.registerAppPlugins), since the
/// headless background run reads the history too.
final class PhotoChangesPlugin: NSObject, FlutterPlugin {
  static let channelName = "dev.calorietracker/photochanges"

  /// photoChangesCollect stops gathering after this many inserted IDs
  /// (an iCloud restore can insert tens of thousands in one change); the
  /// next call resumes from the last processed change.
  static let maxIdentifiers = 10_000

  /// Whether this OS has persistent change history (iOS 16+). An argument
  /// so tests can take the iOS 15 branch on a newer simulator.
  private let historyAvailable: Bool
  /// PHPhotoLibrary.authorizationStatus(for: .readWrite), injectable.
  private let authorization: () -> PHAuthorizationStatus
  /// UIDevice.identifierForVendor, read on the platform thread.
  private let vendorIdentifier: () -> UUID?
  private let queue = DispatchQueue(
    label: "dev.calorietracker.photochanges", qos: .utility)

  init(
    historyAvailable: Bool = PhotoChangesPlugin.systemHasPersistentHistory,
    authorization: @escaping () -> PHAuthorizationStatus = {
      PHPhotoLibrary.authorizationStatus(for: .readWrite)
    },
    vendorIdentifier: @escaping () -> UUID? = { UIDevice.current.identifierForVendor }
  ) {
    self.historyAvailable = historyAvailable
    self.authorization = authorization
    self.vendorIdentifier = vendorIdentifier
  }

  static var systemHasPersistentHistory: Bool {
    if #available(iOS 16.0, *) { return true }
    return false
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(PhotoChangesPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let work: (UUID?) -> [String: Any]
    switch call.method {
    case "currentToken":
      work = { [self] vendor in currentToken(vendor: vendor) }
    case "insertedImagesSince":
      let request = InsertedImagesRequest(args)
      work = { [self] vendor in insertedImages(request, vendor: vendor) }
    case "albumAssetIds":
      let request = AlbumRequest(args)
      work = { [self] _ in albumAssetIds(request) }
    case "assetDates":
      let request = AssetDatesRequest(args)
      work = { [self] _ in assetDates(request) }
    default:
      result(FlutterMethodNotImplemented)
      return
    }
    // UIKit's device identity is read here, on the platform thread.
    let vendor = vendorIdentifier()
    queue.async {
      let reply = work(vendor)
      DispatchQueue.main.async { result(reply) }
    }
  }

  // MARK: - methods (on the utility queue)

  private var hasAccess: Bool {
    let status = authorization()
    return status == .authorized || status == .limited
  }

  private func currentToken(vendor: UUID?) -> [String: Any] {
    var reply = PhotoChangesReply()
    reply.deviceTag = photoChangesDeviceTag(vendor)
    guard historyAvailable else { return reply.with(status: "unsupported") }
    guard hasAccess else { return reply.with(status: "denied") }
    guard reply.deviceTag != nil else {
      return reply.with(status: "error", errorCode: "no_device_tag")
    }
    guard #available(iOS 16.0, *) else { return reply.with(status: "unsupported") }
    guard let token = photoChangesArchive(PHPhotoLibrary.shared().currentChangeToken)
    else { return reply.with(status: "error", errorCode: "archive_failed") }
    reply.token = token
    return reply.with(status: "ok")
  }

  private func insertedImages(_ request: InsertedImagesRequest, vendor: UUID?) -> [String: Any] {
    var reply = PhotoChangesReply()
    reply.deviceTag = photoChangesDeviceTag(vendor)
    reply.ids = []
    reply.truncated = false
    guard historyAvailable else { return reply.with(status: "unsupported") }
    guard hasAccess else { return reply.with(status: "denied") }
    // Without the tag the caller cannot check the token is this phone's;
    // change nothing until it can (identifierForVendor is nil for a while
    // after a restart, before the first unlock).
    guard reply.deviceTag != nil else {
      reply.token = request.token
      return reply.with(status: "error", errorCode: "no_device_tag")
    }
    guard #available(iOS 16.0, *) else { return reply.with(status: "unsupported") }
    let library = PHPhotoLibrary.shared()

    // Restarting from the current token: fresh when none was sent, and
    // history unavailable when the one sent cannot be read back — it still
    // stood for a point in the past, so the caller must rescan.
    func restart(_ status: String, _ code: String?) -> [String: Any] {
      guard let current = photoChangesArchive(library.currentChangeToken) else {
        reply.token = request.token
        return reply.with(status: "error", errorCode: "archive_failed")
      }
      reply.token = current
      return reply.with(status: status, errorCode: code)
    }
    guard let sent = request.token else { return restart("fresh", nil) }
    guard let since = photoChangesUnarchiveToken(sent) else {
      return restart("unavailable", "token_unreadable")
    }

    let collected: PhotoChangesCollection<PHPersistentChangeToken>
    // Wall-clock time: the monotonic clocks (systemUptime,
    // mach_absolute_time) are "required reason" APIs, and a clock change
    // inside this one second only ends the read early or at max_changes.
    let clock = { Date().timeIntervalSinceReferenceDate }
    let started = clock()
    do {
      let changes = try library.fetchPersistentChanges(since: since)
      collected = try photoChangesCollect(
        changes,
        // The fetch itself counts against the budget.
        budget: request.budget - max(0, clock() - started),
        maxChanges: request.maxChanges,
        maxIdentifiers: PhotoChangesPlugin.maxIdentifiers,
        clock: clock,
        token: { $0.changeToken },
        inserted: { try $0.changeDetails(for: .asset).insertedLocalIdentifiers })
    } catch {
      let mapped = photoChangesStatus(for: error)
      if mapped.status == "error" {
        reply.token = sent
        return reply.with(status: "error", errorCode: mapped.errorCode)
      }
      return restart(mapped.status, mapped.errorCode)
    }

    if let last = collected.lastToken {
      guard let next = photoChangesArchive(last) else {
        reply.token = sent
        return reply.with(status: "error", errorCode: "archive_failed")
      }
      reply.token = next
    } else {
      reply.token = sent  // nothing happened since
    }
    reply.truncated = collected.truncated
    let images = newestImages(collected.inserted, limit: request.limit)
    reply.ids = images.ids
    reply.dropped = images.dropped
    return reply.with(status: "ok")
  }

  /// [identifiers] that are still image assets and not hidden, newest
  /// first by creationDate, at most [limit]; dropped counts the older ones
  /// past [limit], which the token has moved past too. An
  /// inserted-then-deleted ID simply does not come back from the fetch.
  private func newestImages(
    _ identifiers: Set<String>, limit: Int
  ) -> (ids: [[String: Any]], dropped: Int) {
    guard !identifiers.isEmpty else { return ([], 0) }
    let options = PHFetchOptions()
    options.includeHiddenAssets = false
    options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: options)
    var out: [[String: Any]] = []
    var dropped = 0
    assets.enumerateObjects { asset, index, stop in
      guard asset.mediaType == .image, !asset.isHidden else { return }
      out.append(photoChangesEntry(asset))
      if out.count >= limit {
        dropped = assets.count - index - 1
        stop.pointee = true
      }
    }
    return (out, dropped)
  }

  private func albumAssetIds(_ request: AlbumRequest) -> [String: Any] {
    guard hasAccess else { return ["status": "denied", "ids": [String]()] }
    guard !request.titles.isEmpty else { return ["status": "ok", "ids": [String]()] }
    let albums = PHAssetCollection.fetchAssetCollections(
      with: .album, subtype: .albumRegular, options: nil)
    var matching: [PHAssetCollection] = []
    albums.enumerateObjects { album, _, _ in
      if photoChangesTitleMatches(album.localizedTitle, request.titles) {
        matching.append(album)
      }
    }
    var ids: [String] = []
    var seen = Set<String>()
    for album in matching where ids.count < request.limit {
      let options = PHFetchOptions()
      options.includeHiddenAssets = false
      options.predicate = NSPredicate(
        format: "mediaType == %d AND creationDate >= %@",
        PHAssetMediaType.image.rawValue, request.since as NSDate)
      options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
      options.fetchLimit = request.limit
      PHAsset.fetchAssets(in: album, options: options).enumerateObjects { asset, _, stop in
        if seen.insert(asset.localIdentifier).inserted {
          ids.append(asset.localIdentifier)
        }
        if ids.count >= request.limit { stop.pointee = true }
      }
    }
    return ["status": "ok", "ids": ids]
  }

  private func assetDates(_ request: AssetDatesRequest) -> [String: Any] {
    guard hasAccess else { return ["status": "denied", "ids": [[String: Any]]()] }
    guard !request.ids.isEmpty else { return ["status": "ok", "ids": [[String: Any]]()] }
    let options = PHFetchOptions()
    options.includeHiddenAssets = false
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: request.ids, options: options)
    var out: [[String: Any]] = []
    assets.enumerateObjects { asset, _, _ in
      guard asset.mediaType == .image, !asset.isHidden else { return }
      out.append(photoChangesEntry(asset))
    }
    return ["status": "ok", "ids": out]
  }
}

// MARK: - arguments

/// insertedImagesSince's arguments, clamped. A missing or empty token means
/// none (fresh).
struct InsertedImagesRequest {
  static let defaultLimit = 200
  static let maxLimit = 500
  static let defaultBudgetMs = 1000
  static let maxBudgetMs = 1500
  static let minBudgetMs = 50
  static let defaultMaxChanges = 5000
  static let maxMaxChanges = 5000

  let token: String?
  let limit: Int
  /// Seconds.
  let budget: TimeInterval
  let maxChanges: Int

  init(_ args: [String: Any]) {
    let raw = (args["token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    token = (raw?.isEmpty ?? true) ? nil : raw
    limit = photoChangesClamp(
      args["limit"], fallback: Self.defaultLimit, min: 1, max: Self.maxLimit)
    budget =
      Double(
        photoChangesClamp(
          args["budget_ms"], fallback: Self.defaultBudgetMs, min: Self.minBudgetMs,
          max: Self.maxBudgetMs)) / 1000.0
    maxChanges = photoChangesClamp(
      args["max_changes"], fallback: Self.defaultMaxChanges, min: 1, max: Self.maxMaxChanges)
  }
}

/// albumAssetIds' arguments: up to 16 non-empty titles of ≤ 64 characters,
/// images created at or after sinceMs (epoch ms; 0 when missing), at most
/// limit IDs.
struct AlbumRequest {
  static let defaultLimit = 500
  static let maxLimit = 1000
  static let maxTitles = 16

  let titles: [String]
  let since: Date
  let limit: Int

  init(_ args: [String: Any]) {
    let raw = args["titles"] as? [Any] ?? []
    titles = Array(
      raw.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && $0.count <= 64 }
        .prefix(Self.maxTitles))
    let sinceMs = (args["sinceMs"] as? NSNumber)?.doubleValue ?? 0
    since = Date(timeIntervalSince1970: sinceMs.isFinite ? sinceMs / 1000.0 : 0)
    limit = photoChangesClamp(
      args["limit"], fallback: Self.defaultLimit, min: 1, max: Self.maxLimit)
  }
}

/// assetDates' arguments: up to 50 distinct non-empty identifiers of at
/// most 256 characters, in the order sent.
struct AssetDatesRequest {
  static let maxIds = 50
  static let maxLength = 256

  let ids: [String]

  init(_ args: [String: Any]) {
    let raw = args["ids"] as? [Any] ?? []
    var seen = Set<String>()
    var ids: [String] = []
    for value in raw {
      guard let id = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !id.isEmpty, id.count <= Self.maxLength, seen.insert(id).inserted
      else { continue }
      ids.append(id)
      if ids.count >= Self.maxIds { break }
    }
    self.ids = ids
  }
}

// MARK: - core (pure; RunnerTests)

/// An integer argument from the channel, [fallback] when missing or not a
/// number, clamped to [min]...[max].
func photoChangesClamp(_ value: Any?, fallback: Int, min: Int, max: Int) -> Int {
  let n = (value as? NSNumber)?.intValue ?? fallback
  return Swift.min(Swift.max(n, min), max)
}

/// The reply map being built; nil fields are left out.
struct PhotoChangesReply {
  var token: String?
  var deviceTag: String?
  var ids: [[String: Any]]?
  var truncated: Bool?
  var dropped: Int?

  func with(status: String, errorCode: String? = nil) -> [String: Any] {
    var map: [String: Any] = ["status": status]
    if let errorCode { map["error_code"] = errorCode }
    if let token { map["token"] = token }
    if let deviceTag { map["device_tag"] = deviceTag }
    if let ids { map["ids"] = ids }
    if let truncated { map["truncated"] = truncated }
    if let dropped { map["dropped"] = dropped }
    return map
  }
}

/// 8 lowercase hex characters of SHA-256 over the identifierForVendor's
/// canonical string; nil without one. Stable for this app on this phone
/// until every app of the vendor is removed (and the local store with it).
func photoChangesDeviceTag(_ vendor: UUID?) -> String? {
  guard let vendor else { return nil }
  let digest = SHA256.hash(data: Data(vendor.uuidString.utf8))
  return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
}

/// [token] archived with secure coding, base64; nil on failure.
func photoChangesArchive(_ token: NSObject & NSSecureCoding) -> String? {
  guard
    let data = try? NSKeyedArchiver.archivedData(
      withRootObject: token, requiringSecureCoding: true)
  else { return nil }
  return data.base64EncodedString()
}

/// The [T] archived in base64 [text], or nil for anything else: not
/// base64, not an archive, or an archive of another class.
func photoChangesUnarchive<T: NSObject & NSSecureCoding>(
  _ text: String, as type: T.Type = T.self
) -> T? {
  guard let data = Data(base64Encoded: text) else { return nil }
  return try? NSKeyedUnarchiver.unarchivedObject(ofClass: type, from: data)
}

@available(iOS 16.0, *)
func photoChangesUnarchiveToken(_ text: String) -> PHPersistentChangeToken? {
  photoChangesUnarchive(text, as: PHPersistentChangeToken.self)
}

/// PHPhotosError codes (PHError.h, iOS 16+), as numbers so this file's
/// mapping compiles and is testable on the iOS 15 floor.
let photoChangesTokenExpiredCode = 3105
let photoChangesDetailsUnavailableCode = 3210

/// A history read's error → its reply status. Only Photos' own "token
/// expired" and "details unavailable" reset the caller's token; anything
/// else is a transient error and keeps it.
func photoChangesStatus(for error: Error) -> (status: String, errorCode: String?) {
  let ns = error as NSError
  if ns.domain == PHPhotosErrorDomain {
    if ns.code == photoChangesTokenExpiredCode { return ("expired", nil) }
    if ns.code == photoChangesDetailsUnavailableCode { return ("unavailable", nil) }
  }
  return ("error", String("\(ns.domain):\(ns.code)".prefix(80)))
}

/// What a bounded read of the change history gathered.
struct PhotoChangesCollection<Token> {
  /// Inserted asset identifiers across the processed changes.
  var inserted = Set<String>()
  /// The last PROCESSED change's token; nil when there were none.
  var lastToken: Token?
  var processed = 0
  /// True when it stopped with changes left over (budget, maxChanges or
  /// maxIdentifiers); resume from [lastToken].
  var truncated = false
}

/// Reads [changes] in order, gathering inserted identifiers, and stops
/// BEFORE the next change once [budget] seconds have passed on [clock],
/// [maxChanges] were processed or [maxIdentifiers] were gathered. At least
/// one change is always processed, so a slow phone still moves forward;
/// truncated is set only when a change was left unprocessed. A change that
/// throws ends the read with that error: the caller's token then still
/// covers it, never skips it.
func photoChangesCollect<Changes: Sequence, Token>(
  _ changes: Changes,
  budget: TimeInterval,
  maxChanges: Int,
  maxIdentifiers: Int,
  clock: () -> TimeInterval,
  token: (Changes.Element) -> Token,
  inserted: (Changes.Element) throws -> Set<String>
) throws -> PhotoChangesCollection<Token> {
  var out = PhotoChangesCollection<Token>()
  let start = clock()
  var iterator = changes.makeIterator()
  while let change = iterator.next() {
    if out.processed > 0
      && (clock() - start >= budget || out.processed >= maxChanges
        || out.inserted.count >= maxIdentifiers)
    {
      out.truncated = true
      break
    }
    out.inserted.formUnion(try inserted(change))
    out.lastToken = token(change)
    out.processed += 1
  }
  return out
}

/// One reply entry: {id, created_ms?, added_ms?}. added_ms (when the asset
/// joined the library) exists from iOS 26.
func photoChangesEntry(_ asset: PHAsset) -> [String: Any] {
  var entry: [String: Any] = ["id": asset.localIdentifier]
  if let created = asset.creationDate {
    entry["created_ms"] = photoChangesMillis(created)
  }
  if #available(iOS 26.0, *) {
    // addedDate is Date in the iOS 26 SDK and Date? in the iOS 27 SDK;
    // binding through an explicit optional compiles with both Xcodes.
    let added: Date? = asset.addedDate
    if let added { entry["added_ms"] = photoChangesMillis(added) }
  }
  return entry
}

func photoChangesMillis(_ date: Date) -> Int64 {
  Int64((date.timeIntervalSince1970 * 1000).rounded())
}

/// Whether an album's [title] is one of [titles], ignoring case and
/// surrounding whitespace.
func photoChangesTitleMatches(_ title: String?, _ titles: [String]) -> Bool {
  guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
  else { return false }
  return titles.contains { $0.caseInsensitiveCompare(title) == .orderedSame }
}

// MARK: - core end
