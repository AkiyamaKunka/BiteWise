import Flutter
import Foundation
import ImageIO

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
/// with the EXIF orientation baked into the pixels and NO metadata copied
/// from the source (no EXIF, GPS, camera or times) — the same strip policy
/// as the Dart path. nil on any failure; the Dart side then falls through.
///
/// Registered for BOTH engines in AppDelegate: the app's implicit engine and
/// the headless one workmanager creates (GeneratedPluginRegistrant only
/// knows pub plugins, never this app-local one).
final class ImageIOPlugin: NSObject, FlutterPlugin {
  static let channelName = "dev.calorietracker/imageio"

  /// One serial worker per engine: the pipeline sends one photo at a time,
  /// and a decode must never run on the platform (main) thread.
  private let queue = DispatchQueue(label: "dev.calorietracker.imageio", qos: .userInitiated)

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(ImageIOPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "downscaleJpeg" else {
      result(FlutterMethodNotImplemented)
      return
    }
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

/// [data] (any format ImageIO reads) → JPEG, long side ≤ [maxPx], quality
/// [quality]/100, orientation applied, no source metadata. nil on failure.
func imageIODownscaleJpeg(_ data: Data, maxPx: Int, quality: Int) -> Data? {
  guard maxPx > 0, !data.isEmpty else { return nil }
  return autoreleasepool { () -> Data? in
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
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions)
    else { return nil }
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

// MARK: - core end
