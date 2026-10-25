import CoreML
import Flutter
import Foundation
import ImageIO
import UIKit
import Vision

/// Photo → small upload JPEG through ImageIO, entirely on the CPU.
///
/// WHY THIS EXISTS (2026-10-18): the background photo scan runs in a
/// headless Flutter engine (workmanager's BGAppRefreshTask). The engine
/// marks the GPU unavailable whenever the app is not in the foreground,
/// which for a background refresh is the whole run, and dart:ui image
/// decoding parks its texture upload until the GPU comes back. So the
/// Dart-side fallback for HEIC (every iPhone camera photo) never finished:
/// no request left the phone, iOS expired the run, the photo stayed
/// reserved, and the next run hung on the same photo. ImageIO decodes
/// HEIC/JPEG/PNG on the CPU with no Flutter involvement, so it works in
/// either engine.
///
/// Channel `dev.calorietracker/imageio`, method `downscaleJpeg`:
///   {bytes: Uint8List, maxPx: int, quality: int (1-100)} → Uint8List?
/// The reply is a JPEG whose long side is at most maxPx (never upscaled),
/// with the EXIF orientation baked into the pixels, sRGB pixels (a P3 HEIC
/// is colour-converted, [imageIOSRGB]) and NO metadata copied from the
/// source (no EXIF, GPS, camera or times) — the same strip policy as the
/// Dart path. nil on any failure; the Dart side then falls through.
///
/// Method `foodScore` (design G3, 2026-10-24): the on-device food check a
/// Meta glasses photo gets before the automatic intake uploads it.
///   {bytes: Uint8List, maxPx: int (default 360), labels: [String],
///    background: bool?} → {status: ok|deferred_gpu|unsupported|error,
///    score?: double, top: [{id, conf}]}
/// A [maxPx] thumbnail (the same decode-bomb guard as the downscale) goes to
/// VNClassifyImageRequest. score = the highest confidence over [labels]
/// (lib/services/photo/food_prefilter.dart kFoodLabels, the one table);
/// top = the five best classes of any kind, for the diagnostics. The
/// request runs on the CPU whenever it can: setComputeDevice on iOS 17+ for
/// every stage supportedComputeStageDevices lists a CPU for, usesCPUOnly
/// before. Where some stage has no CPU device and the app is in the
/// background (iOS refuses GPU work there, the same lesson as the decode
/// above), nothing runs: deferred_gpu, and the photo waits for the
/// foreground. Past [imageIOFoodTimeout] the reply is error. A classifier
/// that answers a black and a white probe alike ([ImageIOBlindCheck], the
/// iOS 26.2 simulator's) is unsupported. Every failure
/// is an answer, never a throw: the Dart side then lets the photo through
/// (fail open), which is what it did before the check existed.
///
/// Registered for BOTH engines in AppDelegate: the app's implicit engine and
/// the headless one workmanager creates (GeneratedPluginRegistrant only
/// knows pub plugins, never this app-local one).
final class ImageIOPlugin: NSObject, FlutterPlugin {
  static let channelName = "dev.calorietracker/imageio"

  /// One serial worker per engine: the pipeline sends one photo at a time,
  /// and a decode must never run on the platform (main) thread.
  private let queue = DispatchQueue(label: "dev.calorietracker.imageio", qos: .userInitiated)

  /// The food check's own worker, never stuck behind a downscale. It only
  /// waits: the Vision work itself runs on [imageIOVisionQueue].
  private let foodQueue = DispatchQueue(
    label: "dev.calorietracker.imageio.food", qos: .userInitiated)

  /// Whether the app is in the background right now; asked on the platform
  /// thread. A background refresh run is, for its whole length.
  private let isBackground: () -> Bool

  /// The classifier behind `foodScore`; tests replace it (a simulator may
  /// have no inference context).
  private let classify: ImageIOClassifier

  init(
    isBackground: @escaping () -> Bool = {
      UIApplication.shared.applicationState == .background
    },
    classify: @escaping ImageIOClassifier = imageIOVisionClassify
  ) {
    self.isBackground = isBackground
    self.classify = classify
    super.init()
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(ImageIOPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "downscaleJpeg":
      handleDownscale(call, result: result)
    case "foodScore":
      handleFoodScore(call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handleFoodScore(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let bytes = args["bytes"] as? FlutterStandardTypedData,
      let labels = args["labels"] as? [String], !labels.isEmpty
    else {
      result(ImageIOFoodScore.error.channelValue)
      return
    }
    let maxPx = (args["maxPx"] as? NSNumber)?.intValue ?? imageIOFoodMaxPx
    // The platform thread's answer, read now: the state can only be asked
    // here, and a photo checked moments later is checked in that state.
    let background = (args["background"] as? Bool ?? false) || isBackground()
    let data = bytes.data
    let classify = self.classify
    foodQueue.async {
      let score = imageIOFoodScore(
        data, maxPx: maxPx, labels: Set(labels), background: background, classify: classify)
      DispatchQueue.main.async { result(score.channelValue) }
    }
  }

  private func handleDownscale(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let bytes = args["bytes"] as? FlutterStandardTypedData,
      let maxPx = (args["maxPx"] as? NSNumber)?.intValue,
      let quality = (args["quality"] as? NSNumber)?.intValue
    else {
      result(nil)
      return
    }
    let data = bytes.data
    queue.async {
      let jpeg = imageIODownscaleJpeg(data, maxPx: maxPx, quality: quality)
      // Channel replies belong on the platform thread.
      DispatchQueue.main.async {
        result(jpeg.map { FlutterStandardTypedData(bytes: $0) })
      }
    }
  }
}

// MARK: - core (ImageIO only; compiled on macOS by the verification harness)

/// Decoded-pixel ceiling for the SOURCE. Thumbnailing subsamples JPEG and
/// HEIC, but not every format can be read at a reduced size, and a
/// crafted 40000×40000 PNG shared into the app must not be able to take the
/// process (the background grant runs under a tight memory limit). Twice
/// the Dart path's 50 MP ceiling still admits every phone camera's
/// full-resolution output; anything bigger falls through to the next
/// decoder (the foreground's engine codec), exactly as before.
let imageIOMaxSourcePixels = 100_000_000

/// [data] (any format ImageIO reads) → an upright image whose long side is
/// at most [maxPx] (never upscaled), decoded from the full image. nil on
/// failure, and for a source over [imageIOMaxSourcePixels], refused from
/// its header before any pixel is decoded.
func imageIOThumbnail(_ data: Data, maxPx: Int) -> CGImage? {
  guard maxPx > 0, !data.isEmpty else { return nil }
  let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
  guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
    CGImageSourceGetCount(source) > 0
  else { return nil }
  // Header-only read: refuse a decode bomb before any pixel is decoded.
  guard
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions)
      as? [CFString: Any],
    let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
    let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
    width > 0, height > 0,
    width.multipliedReportingOverflow(by: height).overflow == false,
    width * height <= imageIOMaxSourcePixels
  else { return nil }
  // Never upscale: the thumbnail is capped at the image's own long side.
  let longSide = min(maxPx, max(width, height))
  let thumbOptions =
    [
      // From the full image, never the tiny embedded preview.
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      // Bakes the EXIF/HEIF orientation into the pixels.
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: longSide,
      kCGImageSourceShouldCacheImmediately: true,
    ] as CFDictionary
  return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions)
}

/// [data] (any format ImageIO reads) → JPEG, long side ≤ [maxPx], quality
/// [quality]/100, orientation applied, no source metadata. nil on failure.
func imageIODownscaleJpeg(_ data: Data, maxPx: Int, quality: Int) -> Data? {
  guard maxPx > 0, !data.isEmpty else { return nil }
  return autoreleasepool { () -> Data? in
    guard let thumb = imageIOThumbnail(data, maxPx: maxPx) else { return nil }
    let image = imageIOSRGB(thumb) ?? thumb
    let out = NSMutableData()
    guard
      let dest = CGImageDestinationCreateWithData(
        out as CFMutableData, "public.jpeg" as CFString, 1, nil)
    else { return nil }
    let q = Double(min(max(quality, 1), 100)) / 100.0
    // Only the compression quality: no source properties are copied, so
    // the output carries no EXIF/GPS/TIFF/IPTC from the original.
    CGImageDestinationAddImage(
      dest, image, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
    guard CGImageDestinationFinalize(dest), out.length > 0 else { return nil }
    return out as Data
  }
}

/// [image] with its pixels converted to sRGB, or nil when it already is
/// sRGB (or the context cannot be made; the caller then encodes [image]).
///
/// Every iPhone camera HEIC is Display P3. Encoded as is, the JPEG holds P3
/// pixel values plus a P3 ICC profile, and anything that re-encodes it
/// without that profile reads P3 values as sRGB: washed-out colour. The
/// owner's server does exactly that (PIL `convert("RGB").save`, no
/// icc_profile). The engine codec this replaced handed over sRGB pixels;
/// so does this. A CoreGraphics bitmap context draws on the CPU, so the
/// GPU-less background engine can run it. Opaque output: a JPEG has no
/// alpha.
func imageIOSRGB(_ image: CGImage) -> CGImage? {
  guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
    image.colorSpace?.name != CGColorSpace.sRGB,
    let ctx = CGContext(
      data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
      bytesPerRow: 0, space: srgb,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
  else { return nil }
  ctx.interpolationQuality = .none  // same size: a copy, colour-matched
  ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  return ctx.makeImage()
}

// MARK: - core end

// MARK: - the food check (ImageIO + Vision; no UIKit, so it compiles on macOS)

/// The thumbnail's long side when the call names none: the classifier looks
/// at about 300 px, and a small decode keeps the background run's memory and
/// time low.
let imageIOFoodMaxPx = 360

/// How long one check may take, thumbnail included. Past it the reply is
/// error and the photo goes on unchecked (fail open); a request that hangs
/// keeps [imageIOVisionQueue] to itself, so every later check times out
/// too instead of starting more work.
let imageIOFoodTimeout: TimeInterval = 1.5

/// Where every check's Vision work runs, one at a time.
let imageIOVisionQueue = DispatchQueue(
  label: "dev.calorietracker.imageio.vision", qos: .userInitiated)

/// What a classifier made of one image.
enum ImageIOClassification {
  /// Every class it scored: (identifier, confidence 0–1).
  case observations([(String, Float)])
  /// It would need a GPU, and the app is in the background.
  case deferGPU
}

/// (thumbnail, app in the background) → classes. Throws what Vision throws.
typealias ImageIOClassifier = (CGImage, Bool) throws -> ImageIOClassification

/// Where a request runs.
enum ImageIOFoodCompute: Equatable {
  /// On the CPU, every stage: the same in the foreground and the background.
  case cpu
  /// Wherever the OS puts it (some stage has no CPU device): foreground only.
  case defaultDevices
  /// Not at all: no CPU device for some stage, and the app is in the
  /// background, where iOS refuses GPU work.
  case deferGPU
}

/// The choice behind [imageIOVisionClassify], on its own so the branch is
/// testable on any runtime.
func imageIOFoodComputeChoice(cpuOnEveryStage: Bool, background: Bool) -> ImageIOFoodCompute {
  if cpuOnEveryStage { return .cpu }
  return background ? .deferGPU : .defaultDevices
}

/// Whether every compute stage of [request] lists a CPU device. Before
/// iOS 17 / macOS 14 there is no such list, and usesCPUOnly is the switch:
/// true.
func imageIOCPUOnEveryStage(_ request: VNRequest) -> Bool {
  if #available(iOS 17.0, macOS 14.0, *) {
    guard let stages = try? request.supportedComputeStageDevices, !stages.isEmpty
    else { return false }
    return stages.values.allSatisfy { devices in
      devices.contains { device in
        if case .cpu = device { return true }
        return false
      }
    }
  }
  return true
}

/// Puts every stage of [request] on its CPU device.
func imageIOUseCPU(_ request: VNRequest) {
  if #available(iOS 17.0, macOS 14.0, *) {
    guard let stages = try? request.supportedComputeStageDevices else { return }
    for (stage, devices) in stages {
      let cpu = devices.first { device in
        if case .cpu = device { return true }
        return false
      }
      if let cpu { request.setComputeDevice(cpu, for: stage) }
    }
  } else {
    request.usesCPUOnly = true
  }
}

/// The production classifier: VNClassifyImageRequest, on the CPU whenever
/// it can be ([imageIOFoodComputeChoice]), once [ImageIOBlindCheck.shared]
/// has found that it sees what it is shown.
func imageIOVisionClassify(_ image: CGImage, background: Bool) throws -> ImageIOClassification {
  try imageIOVisionClassify(image, background: background, blindCheck: .shared)
}

/// [imageIOVisionClassify] with the blind check passed in (tests).
func imageIOVisionClassify(
  _ image: CGImage, background: Bool, blindCheck: ImageIOBlindCheck
) throws -> ImageIOClassification {
  let compute = imageIOFoodComputeChoice(
    cpuOnEveryStage: imageIOCPUOnEveryStage(VNClassifyImageRequest()), background: background)
  if compute == .deferGPU { return .deferGPU }
  let run = { (input: CGImage) throws -> [(String, Float)] in
    let request = VNClassifyImageRequest()
    if compute == .cpu { imageIOUseCPU(request) }
    try VNImageRequestHandler(cgImage: input, options: [:]).perform([request])
    let results: [VNClassificationObservation] = request.results ?? []
    return results.map { ($0.identifier, $0.confidence) }
  }
  guard try blindCheck.seesInput(run) else { throw imageIOBlindClassifierError }
  return .observations(try run(image))
}

// MARK: - the blind check

/// A classifier can run without an error and still not see its input. On
/// the iOS 26.2 simulator (2026-10-24) every image reaches the CPU path as
/// black: a pizza, a plate and a white frame all score outdoor / night_sky
/// ≈ 0.49 — exactly what a black frame scores on a Mac — and a food score
/// near 0, so every automatic glasses photo was tombstoned not food, for
/// good. Before its first classification in a process, the production
/// classifier is shown two flat probes, black and white; a classifier that
/// answers them alike ([imageIOSameAnswer]) cannot tell images apart, and
/// every check on it is unsupported: the photo goes on unchecked (fail
/// open), as it did before the check existed. A classifier that sees moves
/// its top class by about 0.5 between the two (outdoor 0.49 → 0.00).
final class ImageIOBlindCheck {
  static let shared = ImageIOBlindCheck()

  private let lock = NSLock()
  private var verdict: Bool?

  /// The verdict: nil until a check ran to the end.
  var known: Bool? {
    lock.lock()
    defer { lock.unlock() }
    return verdict
  }

  /// Whether [classify] sees its input: the kept verdict, or [classify] on
  /// the probes (kept only when both ran; a throw is rethrown and asks
  /// again next time).
  func seesInput(_ classify: (CGImage) throws -> [(String, Float)]) throws -> Bool {
    if let known { return known }
    guard let black = imageIOFlatProbe(gray: 0), let white = imageIOFlatProbe(gray: 1) else {
      return true  // nothing to show it: no verdict, the check runs as before
    }
    let sees = !imageIOSameAnswer(try classify(black), try classify(white))
    lock.lock()
    verdict = sees
    lock.unlock()
    return sees
  }
}

/// What a blind classifier throws: [imageIOFoodUnsupported] says unsupported.
let imageIOBlindClassifierError = NSError(
  domain: "dev.calorietracker.imageio.food", code: 1,
  userInfo: [
    NSLocalizedDescriptionKey: "the classifier gives a black and a white image the same answer"
  ])

/// A [size] x [size] image of one grey level (0 black, 1 white).
func imageIOFlatProbe(gray: CGFloat, size: Int = 64) -> CGImage? {
  guard
    let ctx = CGContext(
      data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
  else { return nil }
  ctx.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
  ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
  return ctx.makeImage()
}

/// Whether two classifications are the same answer: every class either one
/// scored is within [tolerance] in the other (a class one left out counts as
/// 0). Two empty answers are the same.
func imageIOSameAnswer(
  _ a: [(String, Float)], _ b: [(String, Float)], tolerance: Float = 0.05
) -> Bool {
  var left: [String: Float] = [:]
  for (id, conf) in a { left[id] = max(left[id] ?? 0, conf) }
  var right: [String: Float] = [:]
  for (id, conf) in b { right[id] = max(right[id] ?? 0, conf) }
  for id in Set(left.keys).union(right.keys) {
    if abs((left[id] ?? 0) - (right[id] ?? 0)) > tolerance { return false }
  }
  return true
}

/// One check's answer, as the channel sends it.
struct ImageIOFoodScore: Equatable {
  /// ok | deferred_gpu | unsupported | error
  let status: String
  /// The highest confidence over the labels asked about (status ok only).
  let score: Double?
  /// The best classes of any kind, best first (status ok only).
  let top: [ImageIOFoodClass]

  static let error = ImageIOFoodScore(status: "error", score: nil, top: [])
  static let unsupported = ImageIOFoodScore(status: "unsupported", score: nil, top: [])
  static let deferredGPU = ImageIOFoodScore(status: "deferred_gpu", score: nil, top: [])

  var channelValue: [String: Any] {
    var out: [String: Any] = [
      "status": status,
      "top": top.map { ["id": $0.id, "conf": $0.conf] as [String: Any] },
    ]
    if let score { out["score"] = score }
    return out
  }
}

struct ImageIOFoodClass: Equatable {
  let id: String
  let conf: Double
}

/// How many of the best classes a reply lists.
let imageIOFoodTopCount = 5

/// [observations] scored against [labels]: score = the best confidence
/// among them (0 when none was scored), top = the [imageIOFoodTopCount]
/// best classes overall. Confidences are clamped to 0–1.
func imageIOFoodScoreOf(_ observations: [(String, Float)], labels: Set<String>)
  -> ImageIOFoodScore
{
  func clamp(_ c: Float) -> Double { Double(min(max(c, 0), 1)) }
  var best = 0.0
  for (id, conf) in observations where labels.contains(id) {
    best = max(best, clamp(conf))
  }
  let top = observations
    .sorted { $0.1 > $1.1 }
    .prefix(imageIOFoodTopCount)
    .map { ImageIOFoodClass(id: $0.0, conf: clamp($0.1)) }
  return ImageIOFoodScore(status: "ok", score: best, top: Array(top))
}

/// Whether [error] says this device cannot run the request at all, rather
/// than that this one run failed (a blind classifier, [ImageIOBlindCheck],
/// is one of those).
func imageIOFoodUnsupported(_ error: Error) -> Bool {
  let ns = error as NSError
  if ns.domain == imageIOBlindClassifierError.domain {
    return ns.code == imageIOBlindClassifierError.code
  }
  guard ns.domain == VNErrorDomain else { return false }
  let codes: Set<Int> = [
    VNErrorCode.unsupportedRevision.rawValue,
    VNErrorCode.unsupportedRequest.rawValue,
  ]
  return codes.contains(ns.code)
}

/// Thread-safe slot for the answer of a check that may outlive its wait.
private final class ImageIOFoodSlot {
  private let lock = NSLock()
  private var stored: ImageIOFoodScore?
  func set(_ value: ImageIOFoodScore) {
    lock.lock()
    stored = value
    lock.unlock()
  }
  var value: ImageIOFoodScore? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
}

/// The check behind `foodScore`: [data] → thumbnail ([maxPx]) → [classify]
/// on [queue], waited for at most [timeout]. Never throws:
/// - an empty [labels], bad [maxPx], an undecodable image or a classifier
///   failure is error (unsupported when Vision says the device cannot run
///   it), and so is a check past [timeout];
/// - a classifier that would need the GPU in the background is
///   deferred_gpu.
func imageIOFoodScore(
  _ data: Data, maxPx: Int, labels: Set<String>, background: Bool,
  timeout: TimeInterval = imageIOFoodTimeout,
  queue: DispatchQueue = imageIOVisionQueue,
  classify: @escaping ImageIOClassifier = imageIOVisionClassify
) -> ImageIOFoodScore {
  guard !labels.isEmpty, maxPx > 0, !data.isEmpty else { return .error }
  let slot = ImageIOFoodSlot()
  let done = DispatchSemaphore(value: 0)
  queue.async {
    let answer = autoreleasepool { () -> ImageIOFoodScore in
      guard let thumb = imageIOThumbnail(data, maxPx: maxPx) else { return .error }
      do {
        switch try classify(thumb, background) {
        case .deferGPU:
          return .deferredGPU
        case .observations(let observations):
          return imageIOFoodScoreOf(observations, labels: labels)
        }
      } catch {
        return imageIOFoodUnsupported(error) ? .unsupported : .error
      }
    }
    slot.set(answer)
    done.signal()
  }
  guard done.wait(timeout: .now() + timeout) == .success else { return .error }
  return slot.value ?? .error
}
