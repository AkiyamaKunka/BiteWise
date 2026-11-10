import CoreLocation
import Flutter
import Foundation
import MapKit

/// Food places near a photo's location, from Apple Maps on the phone
/// (design R4, restaurant assist, 2026-10-24).
///
/// WHY THIS EXISTS: restaurant assist (off by default) looks up a chain's
/// published nutrition when a meal photo was taken at one. Which chain is
/// decided ON THE PHONE: MapKit lists the food places around the photo's
/// coordinates, and Dart matches their names against BiteWise's own US
/// chain table. Only that table's canonical name ever reaches an AI
/// recipient; the coordinates go to Apple alone, as when using Maps.
///
/// Channel `dev.calorietracker/places` (Dart side:
/// lib/services/places/places.dart):
///   nearbyFood {lat, lon, radius_m, categories?} →
///     {status: ok|none|throttled|error|unsupported,
///      places: [{name, category, distance_m, url_host?, country?}],
///      error_code?}
///
/// - MKLocalPointsOfInterestRequest with an MKPointOfInterestFilter. With
///   no categories: restaurant, cafe, bakery, brewery, winery, nightlife,
///   plus distillery from iOS 18. food_market only when asked for.
///   Categories this OS cannot search for are left out; when none is left
///   the answer is unsupported.
/// - radius_m is clamped to 40...300.
/// - places are nearest first (distance from the point, whole metres), at
///   most 50. A place without a name or a position is left out.
///   url_host is the place's website host, lowercase ASCII only. country
///   is the place's ISO 3166 alpha-2 code as Apple files it (US; Puerto
///   Rico is PR), two uppercase letters only: Dart reads it only to tell
///   whether the photo was taken in the US (core/meal_country.dart), never
///   stores or shows it. From MKMapItem.addressRepresentations.region on
///   iOS 26+, the placemark's isoCountryCode before.
/// - none: MapKit found nothing (MKError 4, placemarkNotFound, which is how
///   it reports an empty area — never an empty list). throttled: MKError
///   3, loadingThrottled (about 50 requests a minute, live probe
///   2026-10-23); the Dart side backs off. Anything else is error with
///   `<domain>:<code>`; timeout after 3 s (the search is cancelled);
///   bad_arguments for a point that is not one.
///
/// What it never does: no CLLocationManager and no CLGeocoder, so no
/// location permission, no prompt and no NSLocation* key; no reverse
/// geocoding; no place IDs, phone numbers or addresses in the reply. It
/// stores nothing: Apple's terms (developer license, Attachment 6 §2.5)
/// allow Map Data only temporarily, so the reply lives in Dart's memory
/// for one match and is dropped.
///
/// Registered for both engines (AppDelegate.registerAppPlugins), but only
/// the app's engine calls it: the assist runs in the foreground only.
final class PlacesPlugin: NSObject, FlutterPlugin {
  static let channelName = "dev.calorietracker/places"

  /// Seconds before a search that has not answered is cancelled.
  static let defaultTimeout: TimeInterval = 3

  private let search: PlacesSearch
  private let timeout: TimeInterval
  private let systemHasDistillery: Bool

  init(
    search: @escaping PlacesSearch = PlacesPlugin.mapKitSearch,
    timeout: TimeInterval = PlacesPlugin.defaultTimeout,
    systemHasDistillery: Bool = PlacesPlugin.distilleryAvailable
  ) {
    self.search = search
    self.timeout = timeout
    self.systemHasDistillery = systemHasDistillery
  }

  /// MKPointOfInterestCategory.distillery exists from iOS 18.
  static var distilleryAvailable: Bool {
    if #available(iOS 18.0, *) { return true }
    return false
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(PlacesPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "nearbyFood" else {
      result(FlutterMethodNotImplemented)
      return
    }
    let args = call.arguments as? [String: Any] ?? [:]
    guard let query = NearbyFoodQuery(args, systemHasDistillery: systemHasDistillery) else {
      result(placesReply(status: "error", errorCode: "bad_arguments"))
      return
    }
    guard !query.categories.isEmpty else {
      result(placesReply(status: "unsupported"))
      return
    }
    let pending = PlacesPendingCall(result)
    let cancel = search(query) { outcome in
      let reply = placesReply(for: outcome, query: query)
      DispatchQueue.main.async { pending.finish(reply) }
    }
    pending.attach(cancel: cancel)
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
      pending.timeOut(placesReply(status: "error", errorCode: "timeout"))
    }
  }

  /// The production search: one MKLocalSearch over the query's circle.
  /// The returned closure cancels it, and holds it until then.
  static func mapKitSearch(
    _ query: NearbyFoodQuery,
    _ done: @escaping (Result<[PlaceCandidate], Error>) -> Void
  ) -> () -> Void {
    let request = MKLocalPointsOfInterestRequest(center: query.center, radius: query.radius)
    request.pointOfInterestFilter = MKPointOfInterestFilter(including: query.categories)
    let search = MKLocalSearch(request: request)
    search.start { response, error in
      if let response {
        done(.success(response.mapItems.map { PlaceCandidate($0) }))
      } else {
        done(
          .failure(
            error
              ?? NSError(domain: MKErrorDomain, code: Int(MKError.Code.unknown.rawValue))))
      }
    }
    return { search.cancel() }
  }
}

/// Starts a search for [query] and calls back once, on any thread; the
/// returned closure cancels it.
typealias PlacesSearch = (
  _ query: NearbyFoodQuery,
  _ done: @escaping (Result<[PlaceCandidate], Error>) -> Void
) -> () -> Void

/// One nearbyFood call in flight. It replies once, on the main thread:
/// with the search's answer, or with the timeout's, whichever comes first.
/// It holds the search's cancel closure (and through it the search) until
/// then. Touched only on the main thread.
final class PlacesPendingCall {
  private var result: FlutterResult?
  private var cancel: (() -> Void)?

  init(_ result: @escaping FlutterResult) { self.result = result }

  var isOpen: Bool { result != nil }

  func attach(cancel: @escaping () -> Void) {
    guard isOpen else { return }
    self.cancel = cancel
  }

  func finish(_ reply: [String: Any]) {
    guard let result else { return }
    self.result = nil
    cancel = nil
    result(reply)
  }

  /// The search ran out of time: cancelled, and [reply] sent instead.
  func timeOut(_ reply: [String: Any]) {
    guard isOpen else { return }
    let stop = cancel
    finish(reply)
    stop?()
  }
}

// MARK: - arguments

/// nearbyFood's arguments, checked and clamped; nil for a point that is
/// not one.
struct NearbyFoodQuery {
  static let minRadius: CLLocationDistance = 40
  static let maxRadius: CLLocationDistance = 300
  static let defaultRadius: CLLocationDistance = 100

  let center: CLLocationCoordinate2D
  /// Metres.
  let radius: CLLocationDistance
  let categories: [MKPointOfInterestCategory]

  init?(_ args: [String: Any], systemHasDistillery: Bool) {
    guard let lat = (args["lat"] as? NSNumber)?.doubleValue,
      let lon = (args["lon"] as? NSNumber)?.doubleValue,
      lat.isFinite, lon.isFinite
    else { return nil }
    let center = CLLocationCoordinate2D(latitude: lat, longitude: lon)
    guard CLLocationCoordinate2DIsValid(center) else { return nil }
    self.center = center
    let asked = (args["radius_m"] as? NSNumber)?.doubleValue ?? Self.defaultRadius
    radius = Swift.min(
      Swift.max(asked.isFinite ? asked : Self.defaultRadius, Self.minRadius),
      Swift.min(Self.maxRadius, MKLocalPointsOfInterestRequest.maxRadius))
    let names = (args["categories"] as? [Any])?.compactMap { $0 as? String } ?? []
    categories = placesCategories(names, systemHasDistillery: systemHasDistillery)
  }
}

// MARK: - core (pure; RunnerTests)

/// The Dart names (lib/services/places/places.dart PlaceCategory) for the
/// categories this channel searches, minus distillery, which needs iOS 18
/// ([placesCategory]).
let placesCategoryTable: [(name: String, category: MKPointOfInterestCategory)] = [
  ("restaurant", .restaurant),
  ("cafe", .cafe),
  ("bakery", .bakery),
  ("brewery", .brewery),
  ("winery", .winery),
  ("nightlife", .nightlife),
  ("food_market", .foodMarket),
]

/// Searched when the caller names no category: food_market only on request.
let placesDefaultCategoryNames = [
  "restaurant", "cafe", "bakery", "brewery", "winery", "nightlife", "distillery",
]

/// The category for a Dart [name]; nil for one this OS cannot search for.
func placesCategory(_ name: String, systemHasDistillery: Bool) -> MKPointOfInterestCategory? {
  if name == "distillery" {
    guard systemHasDistillery, #available(iOS 18.0, *) else { return nil }
    return .distillery
  }
  return placesCategoryTable.first { $0.name == name }?.category
}

/// The categories to search for [names], in order, without repeats; the
/// defaults when [names] is empty. Unknown names are left out.
func placesCategories(_ names: [String], systemHasDistillery: Bool) -> [MKPointOfInterestCategory]
{
  var out: [MKPointOfInterestCategory] = []
  for name in names.isEmpty ? placesDefaultCategoryNames : names {
    guard let category = placesCategory(name, systemHasDistillery: systemHasDistillery),
      !out.contains(category)
    else { continue }
    out.append(category)
  }
  return out
}

/// A place's category as the Dart side names it; "other" for anything
/// outside the table (MapKit can list a place under a category the filter
/// did not ask for) or none.
func placesCategoryName(_ category: MKPointOfInterestCategory?) -> String {
  guard let category else { return "other" }
  if #available(iOS 18.0, *), category == .distillery { return "distillery" }
  return placesCategoryTable.first { $0.category == category }?.name ?? "other"
}

/// A search error → its reply status. MapKit reports an empty area as
/// placemarkNotFound (4) and too many requests as loadingThrottled (3).
func placesStatus(for error: Error) -> (status: String, errorCode: String?) {
  let ns = error as NSError
  if ns.domain == MKErrorDomain {
    if ns.code == Int(MKError.Code.placemarkNotFound.rawValue) { return ("none", nil) }
    if ns.code == Int(MKError.Code.loadingThrottled.rawValue) { return ("throttled", nil) }
  }
  return ("error", String("\(ns.domain):\(ns.code)".prefix(80)))
}

/// What the reply needs from one MKMapItem, and nothing more.
struct PlaceCandidate {
  var name: String?
  var category: MKPointOfInterestCategory?
  var location: CLLocation?
  var url: URL?
  /// The ISO country code as MapKit gives it (any spelling; the reply
  /// keeps only a clean alpha-2 code, [placesCountryCode]).
  var country: String?

  init(
    name: String?, category: MKPointOfInterestCategory?, location: CLLocation?, url: URL? = nil,
    country: String? = nil
  ) {
    self.name = name
    self.category = category
    self.location = location
    self.url = url
    self.country = country
  }

  init(_ item: MKMapItem) {
    name = item.name
    category = item.pointOfInterestCategory
    url = item.url
    if #available(iOS 26.0, *) {
      // Explicit optionals, so this compiles whichever way an SDK declares
      // MKMapItem.location, addressRepresentations or its region.
      let location: CLLocation? = item.location
      self.location = location
      let address: MKAddressRepresentations? = item.addressRepresentations
      let region: Locale.Region? = address?.region
      country = region?.identifier
    } else {
      location = item.placemark.location
      country = item.placemark.isoCountryCode
    }
  }
}

/// The most places one reply carries (MapKit itself stops at about 45).
let placesMaxPlaces = 50
/// Longest name sent on, in characters.
let placesMaxNameLength = 120

/// The reply map; places always present (empty unless ok).
func placesReply(
  status: String, places: [[String: Any]] = [], errorCode: String? = nil
) -> [String: Any] {
  var map: [String: Any] = ["status": status, "places": places]
  if let errorCode { map["error_code"] = errorCode }
  return map
}

/// A search's outcome → the reply. A search that found places none of
/// which has a name and a position is none, like an empty area.
func placesReply(
  for outcome: Result<[PlaceCandidate], Error>, query: NearbyFoodQuery
) -> [String: Any] {
  switch outcome {
  case .failure(let error):
    let mapped = placesStatus(for: error)
    return placesReply(status: mapped.status, errorCode: mapped.errorCode)
  case .success(let candidates):
    let places = placesEntries(candidates, center: query.center)
    return placesReply(status: places.isEmpty ? "none" : "ok", places: places)
  }
}

/// [candidates] → reply entries, nearest first (ties by name), at most
/// [limit]: {name, category, distance_m, url_host?, country?}.
func placesEntries(
  _ candidates: [PlaceCandidate], center: CLLocationCoordinate2D,
  limit: Int = placesMaxPlaces
) -> [[String: Any]] {
  let here = CLLocation(latitude: center.latitude, longitude: center.longitude)
  var rows: [(distance: Int, name: String, entry: [String: Any])] = []
  for candidate in candidates {
    guard let name = placesCleanName(candidate.name), let location = candidate.location,
      CLLocationCoordinate2DIsValid(location.coordinate)
    else { continue }
    let metres = location.distance(from: here)
    guard metres.isFinite, metres >= 0 else { continue }
    let distance = Int(metres.rounded())
    var entry: [String: Any] = [
      "name": name,
      "category": placesCategoryName(candidate.category),
      "distance_m": distance,
    ]
    if let host = placesUrlHost(candidate.url) { entry["url_host"] = host }
    if let country = placesCountryCode(candidate.country) { entry["country"] = country }
    rows.append((distance, name, entry))
  }
  rows.sort { $0.distance != $1.distance ? $0.distance < $1.distance : $0.name < $1.name }
  return rows.prefix(max(0, limit)).map(\.entry)
}

/// [name] without control characters or surrounding whitespace, at most
/// [placesMaxNameLength] characters; nil when nothing is left.
func placesCleanName(_ name: String?) -> String? {
  guard let name else { return nil }
  let kept = String(
    String.UnicodeScalarView(
      name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
  ).trimmingCharacters(in: .whitespacesAndNewlines)
  guard !kept.isEmpty else { return nil }
  return String(kept.prefix(placesMaxNameLength))
}

/// [url]'s host, lowercased, when it is a plain ASCII hostname: labels of
/// letters, digits and '-', at least two, joined by single dots, at most
/// 253 characters (Dart's decoder checks the same shape); nil otherwise.
func placesUrlHost(_ url: URL?) -> String? {
  guard let host = url?.host?.lowercased(), host.count <= 253, host.contains("."),
    !host.hasPrefix("."), !host.hasSuffix("."), !host.contains(".."),
    host.unicodeScalars.allSatisfy({
      ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "."
    })
  else { return nil }
  return host
}

/// [code] as an ISO 3166 alpha-2 code: two ASCII letters, uppercased
/// (Dart's decoder checks the same shape); nil for anything else — a
/// numeric UN M49 region, a longer code, an empty string.
func placesCountryCode(_ code: String?) -> String? {
  guard let code = code?.trimmingCharacters(in: .whitespaces).uppercased(), code.count == 2,
    code.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) })
  else { return nil }
  return code
}

// MARK: - core end
