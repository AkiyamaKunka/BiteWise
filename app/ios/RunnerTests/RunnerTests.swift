import Flutter
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import Runner

/// The native ImageIO downscaler (Runner/ImageIOPlugin.swift) — the only
/// decoder the iOS background engine has for HEIC, where dart:ui never
/// finishes because the engine's GPU is off (2026-10-18).
///
/// Every input is built here from a CGImage, so the test runs on any
/// simulator without fixtures: a landscape image whose stored TOP-LEFT
/// quadrant is red, written with EXIF orientation 6 (display = stored
/// rotated 90 degrees clockwise), a GPS block, an EXIF capture time and a
/// camera make/model. A correct output is a JPEG, displayed upright as
/// portrait (width and height swapped), with the red quadrant now at the
/// TOP-RIGHT, its long side capped, and none of that metadata.
class ImageIODownscaleTests: XCTestCase {

  // MARK: - fixtures

  /// width x height pixels, opaque; the top-left quadrant (in stored
  /// pixel space, row 0 = top) is pure red, the rest pure blue.
  private func makeImage(width: Int, height: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: 0, space: space,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // CoreGraphics' origin is bottom-left: the stored top-left quadrant is
    // the upper half of y.
    ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    ctx.fill(
      CGRect(x: 0, y: height / 2, width: width / 2, height: height - height / 2))
    return ctx.makeImage()!
  }

  /// The metadata a camera photo carries and an upload must never: GPS,
  /// capture time, camera make/model — plus the orientation to bake.
  private var cameraProperties: [CFString: Any] {
    [
      kCGImagePropertyOrientation: 6,
      kCGImagePropertyGPSDictionary: [
        kCGImagePropertyGPSLatitude: 12.3456,
        kCGImagePropertyGPSLatitudeRef: "N",
        kCGImagePropertyGPSLongitude: 65.4321,
        kCGImagePropertyGPSLongitudeRef: "E",
        kCGImagePropertyGPSAltitude: 100.0,
      ] as [CFString: Any],
      kCGImagePropertyExifDictionary: [
        kCGImagePropertyExifDateTimeOriginal: "2026:10:18 12:34:56",
        kCGImagePropertyExifDateTimeDigitized: "2026:10:18 12:34:56",
      ] as [CFString: Any],
      kCGImagePropertyTIFFDictionary: [
        kCGImagePropertyTIFFMake: "Apple",
        kCGImagePropertyTIFFModel: "iPhone",
        kCGImagePropertyTIFFDateTime: "2026:10:18 12:34:56",
      ] as [CFString: Any],
    ]
  }

  private func encode(
    _ image: CGImage, as type: UTType, properties: [CFString: Any]
  ) throws -> Data {
    let out = NSMutableData()
    guard
      let dest = CGImageDestinationCreateWithData(
        out as CFMutableData, type.identifier as CFString, 1, nil)
    else {
      throw XCTSkip("this runtime cannot encode \(type.identifier)")
    }
    var props = properties
    props[kCGImageDestinationLossyCompressionQuality] = 0.9
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(dest), "encode \(type.identifier)")
    return out as Data
  }

  private func properties(of data: Data) -> [CFString: Any] {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
      let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
    else { return [:] }
    return props
  }

  private func typeIdentifier(of data: Data) -> String? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceGetType(src) as String?
  }

  private func pixelSize(_ props: [CFString: Any]) -> (w: Int, h: Int) {
    (
      (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? -1,
      (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? -1
    )
  }

  /// RGBA of the decoded [data] at (x, y), y measured from the TOP.
  private func pixel(of data: Data, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
    let src = CGImageSourceCreateWithData(data as CFData, nil)!
    let image = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    let w = image.width
    let h = image.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(
      data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    // A bitmap context's memory is top row first.
    let i = (y * w + x) * 4
    return (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]))
  }

  private func isRed(_ p: (r: Int, g: Int, b: Int)) -> Bool {
    p.r > 200 && p.g < 60 && p.b < 60
  }

  private func isBlue(_ p: (r: Int, g: Int, b: Int)) -> Bool {
    p.b > 200 && p.r < 60 && p.g < 60
  }

  /// Everything an upload must satisfy, for an orientation-6 source of
  /// stored size [srcW] x [srcH] (landscape) downscaled to [maxPx].
  private func assertUploadJpeg(
    _ out: Data?, srcW: Int, srcH: Int, maxPx: Int,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    guard let out else {
      XCTFail("downscaler returned nil", file: file, line: line)
      return
    }
    // JPEG magic.
    XCTAssertGreaterThan(out.count, 4, file: file, line: line)
    XCTAssertEqual(out[out.startIndex], 0xFF, file: file, line: line)
    XCTAssertEqual(out[out.startIndex + 1], 0xD8, file: file, line: line)
    XCTAssertEqual(typeIdentifier(of: out), UTType.jpeg.identifier, file: file, line: line)

    let props = properties(of: out)
    let (w, h) = pixelSize(props)
    // Long side capped, never upscaled.
    let expectedLong = min(maxPx, max(srcW, srcH))
    XCTAssertEqual(max(w, h), expectedLong, "long side", file: file, line: line)
    XCTAssertLessThanOrEqual(max(w, h), maxPx, file: file, line: line)
    // Orientation 6 baked into the pixels: the landscape source is now a
    // portrait image, aspect kept (to within a pixel of rounding).
    XCTAssertGreaterThan(h, w, "orientation 6 must swap width/height", file: file, line: line)
    let expectedShort = Double(expectedLong) * Double(min(srcW, srcH)) / Double(max(srcW, srcH))
    XCTAssertEqual(Double(w), expectedShort, accuracy: 1.5, "aspect", file: file, line: line)
    // ...and no orientation tag left to apply a second time.
    let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    XCTAssertEqual(orientation, 1, "orientation tag", file: file, line: line)
    // The stored top-left (red) displays at the top-right after a 90 degree
    // clockwise turn; the top-left of the output is stored bottom-left (blue).
    XCTAssertTrue(
      isRed(pixel(of: out, x: w - 1 - w / 8, y: h / 8)),
      "top-right must be the stored top-left quadrant (red)", file: file, line: line)
    XCTAssertTrue(
      isBlue(pixel(of: out, x: w / 8, y: h / 8)),
      "top-left must be the stored bottom-left quadrant (blue)", file: file, line: line)

    // No source metadata.
    XCTAssertNil(props[kCGImagePropertyGPSDictionary], "GPS leaked", file: file, line: line)
    let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    XCTAssertNil(
      exif[kCGImagePropertyExifDateTimeOriginal], "EXIF DateTimeOriginal leaked",
      file: file, line: line)
    XCTAssertNil(
      exif[kCGImagePropertyExifDateTimeDigitized], "EXIF DateTimeDigitized leaked",
      file: file, line: line)
    let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
    XCTAssertNil(tiff[kCGImagePropertyTIFFMake], "camera make leaked", file: file, line: line)
    XCTAssertNil(tiff[kCGImagePropertyTIFFModel], "camera model leaked", file: file, line: line)
    XCTAssertNil(tiff[kCGImagePropertyTIFFDateTime], "TIFF time leaked", file: file, line: line)
  }

  /// Guards the fixture itself: the input really carries what the output
  /// must not, or the "no GPS" assertions would prove nothing.
  private func assertCarriesCameraMetadata(
    _ data: Data, type: UTType, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(typeIdentifier(of: data), type.identifier, file: file, line: line)
    let props = properties(of: data)
    XCTAssertEqual(
      (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 6, file: file, line: line)
    XCTAssertNotNil(props[kCGImagePropertyGPSDictionary], "fixture GPS", file: file, line: line)
    let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    XCTAssertNotNil(
      exif[kCGImagePropertyExifDateTimeOriginal], "fixture capture time", file: file, line: line)
  }

  // MARK: - HEIC (every iPhone camera photo)

  func testHeicWithOrientation6AndGpsBecomesUprightJpegWithoutMetadata() throws {
    let heic = try encode(
      makeImage(width: 2000, height: 1500), as: .heic, properties: cameraProperties)
    assertCarriesCameraMetadata(heic, type: .heic)

    // The analysis size the Dart side asks for (kAnalysisLongSidePx, q85).
    let out = imageIODownscaleJpeg(heic, maxPx: 1568, quality: 85)
    assertUploadJpeg(out, srcW: 2000, srcH: 1500, maxPx: 1568)
  }

  func testHeicThumbnailSize() throws {
    let heic = try encode(
      makeImage(width: 2000, height: 1500), as: .heic, properties: cameraProperties)
    // The history thumbnail size (kThumbLongSidePx, q70).
    let out = imageIODownscaleJpeg(heic, maxPx: 160, quality: 70)
    assertUploadJpeg(out, srcW: 2000, srcH: 1500, maxPx: 160)
  }

  // MARK: - JPEG

  func testJpegWithOrientation6AndGpsBecomesUprightJpegWithoutMetadata() throws {
    let jpeg = try encode(
      makeImage(width: 1600, height: 1200), as: .jpeg, properties: cameraProperties)
    assertCarriesCameraMetadata(jpeg, type: .jpeg)

    let out = imageIODownscaleJpeg(jpeg, maxPx: 1568, quality: 85)
    assertUploadJpeg(out, srcW: 1600, srcH: 1200, maxPx: 1568)
  }

  func testSmallJpegIsNeverUpscaled() throws {
    let jpeg = try encode(
      makeImage(width: 400, height: 300), as: .jpeg, properties: cameraProperties)
    let out = imageIODownscaleJpeg(jpeg, maxPx: 1568, quality: 85)
    // Long side stays 400 (expectedLong = min(maxPx, 400)).
    assertUploadJpeg(out, srcW: 400, srcH: 300, maxPx: 1568)
  }

  // MARK: - colour (every iPhone camera HEIC is Display P3)

  /// The centre pixel's RAW values — drawn into the image's own colour
  /// space, so nothing is colour-matched — and that space's name.
  private func rawCentre(of data: Data) -> (space: String?, rgb: (r: Int, g: Int, b: Int)) {
    let src = CGImageSourceCreateWithData(data as CFData, nil)!
    let image = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    let space = image.colorSpace!
    let w = image.width
    let h = image.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(
      data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let i = ((h / 2) * w + w / 2) * 4
    return (space.name as String?, (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2])))
  }

  /// A P3 upload keeps P3 values behind a P3 profile, and whatever drops
  /// the profile (the owner's server re-encodes with PIL, which does) reads
  /// them as sRGB: washed-out colour. The engine codec ImageIO replaced
  /// handed over sRGB pixels; the downscaler must too.
  func testDisplayP3HeicBecomesSRGBPixels() throws {
    let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    let ctx = CGContext(
      data: nil, width: 2000, height: 1500, bitsPerComponent: 8, bytesPerRow: 0,
      space: p3, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    // Pure sRGB red, which CoreGraphics stores in P3 as about (234, 51, 35).
    ctx.setFillColor(
      CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [1, 0, 0, 1])!)
    ctx.fill(CGRect(x: 0, y: 0, width: 2000, height: 1500))
    let heic = try encode(ctx.makeImage()!, as: .heic, properties: [:])

    // The fixture really is P3, its raw red visibly not sRGB red.
    let source = rawCentre(of: heic)
    XCTAssertEqual(source.space, CGColorSpace.displayP3 as String, "fixture colour space")
    XCTAssertGreaterThan(source.rgb.g, 35, "fixture raw green \(source.rgb)")

    let out = try XCTUnwrap(imageIODownscaleJpeg(heic, maxPx: 1568, quality: 85))
    let result = rawCentre(of: out)
    XCTAssertEqual(result.space, CGColorSpace.sRGB as String, "output colour space")
    let profile = properties(of: out)[kCGImagePropertyProfileName] as? String ?? ""
    XCTAssertTrue(profile.hasPrefix("sRGB"), "output profile \(profile)")
    // The raw values themselves are sRGB red: right even with the profile
    // thrown away.
    XCTAssertTrue(
      result.rgb.r > 240 && result.rgb.g < 25 && result.rgb.b < 25,
      "raw output pixel \(result.rgb)")
  }

  // MARK: - failures answer nil, never crash

  func testUnusableInputsReturnNil() {
    XCTAssertNil(imageIODownscaleJpeg(Data(), maxPx: 1568, quality: 85), "empty")
    XCTAssertNil(
      imageIODownscaleJpeg(Data((0..<4096).map { UInt8($0 & 0xFF) }), maxPx: 1568, quality: 85),
      "garbage")
    // A JPEG header with nothing after it.
    XCTAssertNil(
      imageIODownscaleJpeg(Data([0xFF, 0xD8, 0xFF, 0xE0]), maxPx: 1568, quality: 85),
      "truncated")
  }

  func testNonPositiveMaxPxReturnsNil() throws {
    let jpeg = try encode(makeImage(width: 400, height: 300), as: .jpeg, properties: [:])
    XCTAssertNil(imageIODownscaleJpeg(jpeg, maxPx: 0, quality: 85))
    XCTAssertNil(imageIODownscaleJpeg(jpeg, maxPx: -1, quality: 85))
  }

  // MARK: - the channel contract the Dart side calls

  /// lib/services/analyzer/platform_decode.dart downscaleViaImageIO sends
  /// {bytes, maxPx, quality} on 'dev.calorietracker/imageio' and expects a
  /// Uint8List (FlutterStandardTypedData) or nil.
  func testChannelNameMatchesDart() {
    XCTAssertEqual(ImageIOPlugin.channelName, "dev.calorietracker/imageio")
  }

  func testHandleDownscaleJpegRepliesWithTypedDataOnMain() throws {
    let heic = try encode(
      makeImage(width: 2000, height: 1500), as: .heic, properties: cameraProperties)
    let call = FlutterMethodCall(
      methodName: "downscaleJpeg",
      arguments: [
        "bytes": FlutterStandardTypedData(bytes: heic),
        "maxPx": 1568,
        "quality": 85,
      ])
    let replied = expectation(description: "reply")
    var reply: Any?
    var onMain = false
    ImageIOPlugin().handle(call) { value in
      reply = value
      onMain = Thread.isMainThread
      replied.fulfill()
    }
    wait(for: [replied], timeout: 15)
    XCTAssertTrue(onMain, "channel replies belong on the platform thread")
    guard let typed = reply as? FlutterStandardTypedData else {
      XCTFail("expected FlutterStandardTypedData, got \(String(describing: reply))")
      return
    }
    assertUploadJpeg(typed.data, srcW: 2000, srcH: 1500, maxPx: 1568)
  }

  func testHandleRepliesNilForBadArgumentsAndGarbage() {
    let cases: [Any?] = [
      nil,
      ["bytes": FlutterStandardTypedData(bytes: Data([1, 2, 3])), "maxPx": 1568, "quality": 85],
      ["maxPx": 1568, "quality": 85],  // no bytes
      ["bytes": FlutterStandardTypedData(bytes: Data([1])), "quality": 85],  // no maxPx
    ]
    for (i, args) in cases.enumerated() {
      let replied = expectation(description: "reply \(i)")
      var reply: Any? = "unset"
      ImageIOPlugin().handle(FlutterMethodCall(methodName: "downscaleJpeg", arguments: args)) {
        reply = $0
        replied.fulfill()
      }
      wait(for: [replied], timeout: 15)
      XCTAssertNil(reply, "case \(i) must reply nil")
    }
  }

  func testUnknownMethodIsNotImplemented() {
    let replied = expectation(description: "reply")
    var reply: Any?
    ImageIOPlugin().handle(FlutterMethodCall(methodName: "nope", arguments: nil)) {
      reply = $0
      replied.fulfill()
    }
    wait(for: [replied], timeout: 5)
    XCTAssertTrue((reply as AnyObject?) === FlutterMethodNotImplemented)
  }
}

/// The background run's launch stamp (AppDelegate.stampBackgroundLaunch):
/// Dart reads it as prefs 'background.native_launch_iso' and counts the
/// run's time budgets from it (lib/ui/background_glue.dart).
class BackgroundLaunchStampTests: XCTestCase {
  func testStampIsUtcIsoWithMillisecondsUnderTheSharedPreferencesKey() {
    XCTAssertEqual(
      AppDelegate.backgroundLaunchDefaultsKey, "flutter.background.native_launch_iso")
    let suite = "BackgroundLaunchStampTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let now = Date(timeIntervalSince1970: 1_792_400_000.25)
    AppDelegate.stampBackgroundLaunch(defaults, now: now)
    let stamp = defaults.string(forKey: AppDelegate.backgroundLaunchDefaultsKey)
    XCTAssertNotNil(stamp)
    // The shape Dart's DateTime.parse reads as a UTC instant.
    XCTAssertNotNil(
      stamp!.range(
        of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#, options: .regularExpression),
      stamp!)
    let parse = ISO8601DateFormatter()
    parse.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    XCTAssertEqual(
      parse.date(from: stamp!)!.timeIntervalSince1970, now.timeIntervalSince1970,
      accuracy: 0.001)
  }
}

/// The backup-excluded local store's directory (AppDelegate
/// .prepareLocalStore, design F1): Dart's LocalNoBackupStore writes only
/// into a directory this made and flagged, so a missing flag would put
/// location hints and the device-bound photo change token into backups.
class LocalStoreDirectoryTests: XCTestCase {
  private var scratch: URL!

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("LocalStoreDirectoryTests.\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: scratch)
  }

  private func isExcluded(_ url: URL) throws -> Bool? {
    var fresh = url
    fresh.removeAllCachedResourceValues()
    return try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
  }

  func testNameMatchesDart() {
    XCTAssertEqual(AppDelegate.localStoreDirectoryName, "bitewise_local")
  }

  func testCreatesTheDirectoryExcludedFromBackup() throws {
    let made = try XCTUnwrap(AppDelegate.prepareLocalStore(in: scratch))
    XCTAssertEqual(made.lastPathComponent, "bitewise_local")
    XCTAssertEqual(made.deletingLastPathComponent().standardizedFileURL.path,
                   scratch.standardizedFileURL.path)
    var isDirectory: ObjCBool = false
    XCTAssertTrue(FileManager.default.fileExists(atPath: made.path, isDirectory: &isDirectory))
    XCTAssertTrue(isDirectory.boolValue)
    XCTAssertEqual(try isExcluded(made), true)
  }

  func testIdempotentAndReappliesAClearedFlagWithoutTouchingDocuments() throws {
    var made = try XCTUnwrap(AppDelegate.prepareLocalStore(in: scratch))
    let document = made.appendingPathComponent("photo_change_cursor.json")
    try Data(#"{"v":1}"#.utf8).write(to: document)
    // A restore or an older build left the flag off.
    var off = URLResourceValues()
    off.isExcludedFromBackup = false
    try made.setResourceValues(off)
    XCTAssertEqual(try isExcluded(made), false)

    XCTAssertNotNil(AppDelegate.prepareLocalStore(in: scratch))
    XCTAssertNotNil(AppDelegate.prepareLocalStore(in: scratch))
    XCTAssertEqual(try isExcluded(made), true)
    XCTAssertEqual(try Data(contentsOf: document), Data(#"{"v":1}"#.utf8))
  }

  func testFailuresReturnNilAndNeverThrow() throws {
    XCTAssertNil(AppDelegate.prepareLocalStore(in: nil))
    // A file where the directory belongs.
    try Data("in the way".utf8).write(
      to: scratch.appendingPathComponent(AppDelegate.localStoreDirectoryName))
    XCTAssertNil(AppDelegate.prepareLocalStore(in: scratch))
  }

  /// The test host is the app itself, so its launch already ran the real
  /// call: the store's directory under Application Support is there and
  /// flagged.
  func testTheAppLaunchPreparedTheRealDirectory() throws {
    let support = try XCTUnwrap(
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
    let real = support.appendingPathComponent(
      AppDelegate.localStoreDirectoryName, isDirectory: true)
    var isDirectory: ObjCBool = false
    XCTAssertTrue(FileManager.default.fileExists(atPath: real.path, isDirectory: &isDirectory))
    XCTAssertTrue(isDirectory.boolValue)
    XCTAssertEqual(try isExcluded(real), true)
  }
}

/// The background-time channel (Runner/BackgroundTimePlugin.swift): one
/// task per photo, begun and ended from Dart (background_time.dart). A
/// task left open gets the app killed, so every way of ending one is
/// pinned here. Hosted in the running app, so UIApplication is real.
class BackgroundTimePluginTests: XCTestCase {
  private func call(
    _ plugin: BackgroundTimePlugin, _ method: String, _ args: Any?
  ) -> Any? {
    var reply: Any? = "unset"
    plugin.handle(FlutterMethodCall(methodName: method, arguments: args)) { reply = $0 }
    return reply
  }

  func testBeginHandsOutDistinctTokensAndEndClosesEach() {
    let plugin = BackgroundTimePlugin()
    let first = call(plugin, "begin", ["name": "photo"]) as? Int
    let second = call(plugin, "begin", ["name": "photo"]) as? Int
    XCTAssertNotNil(first)
    XCTAssertNotNil(second)
    XCTAssertNotEqual(first, second)
    XCTAssertEqual(plugin.openTaskCount, 2)
    XCTAssertNil(call(plugin, "end", ["id": first!]))
    XCTAssertEqual(plugin.openTaskCount, 1)
    XCTAssertNil(call(plugin, "end", ["id": second!]))
    XCTAssertEqual(plugin.openTaskCount, 0)
  }

  func testEndIsNeverDoubledAndUnknownTokensAreIgnored() {
    let plugin = BackgroundTimePlugin()
    let token = call(plugin, "begin", ["name": "photo"]) as! Int
    XCTAssertNil(call(plugin, "end", ["id": token]))
    XCTAssertNil(call(plugin, "end", ["id": token]))
    XCTAssertNil(call(plugin, "end", ["id": token + 1000]))
    XCTAssertNil(call(plugin, "end", nil))
    XCTAssertEqual(plugin.openTaskCount, 0)
  }

  func testBeginWithoutANameStillBegins() {
    let plugin = BackgroundTimePlugin()
    let token = call(plugin, "begin", nil) as? Int
    XCTAssertNotNil(token)
    XCTAssertNil(call(plugin, "end", ["id": token!]))
  }

  func testUnknownMethodIsNotImplemented() {
    let reply = call(BackgroundTimePlugin(), "nope", nil)
    XCTAssertTrue((reply as AnyObject?) === FlutterMethodNotImplemented)
  }
}

/// The photo change history channel (Runner/PhotoChangesPlugin.swift,
/// design G1a): which photos were added since a saved token, whatever
/// date they carry. Everything that decides what the caller does with its
/// token — the status mapping, where a bounded read stops, the device tag —
/// is pinned here without a photo library; the library itself is exercised
/// when the test host has Photos access, and end to end by
/// `scripts/run_e2e_ios.sh --scenario late_import_native`.
class PhotoChangesTests: XCTestCase {

  // MARK: - helpers

  private func call(
    _ plugin: PhotoChangesPlugin, _ method: String, _ args: Any? = nil,
    file: StaticString = #filePath, line: UInt = #line
  ) -> (reply: Any?, onMain: Bool) {
    let replied = expectation(description: "\(method) reply")
    var reply: Any?
    var onMain = false
    plugin.handle(FlutterMethodCall(methodName: method, arguments: args)) {
      reply = $0
      onMain = Thread.isMainThread
      replied.fulfill()
    }
    wait(for: [replied], timeout: 30)
    return (reply, onMain)
  }

  private func map(
    _ plugin: PhotoChangesPlugin, _ method: String, _ args: Any? = nil,
    file: StaticString = #filePath, line: UInt = #line
  ) -> [String: Any] {
    let (reply, onMain) = call(plugin, method, args, file: file, line: line)
    XCTAssertTrue(onMain, "channel replies belong on the platform thread", file: file, line: line)
    guard let map = reply as? [String: Any] else {
      XCTFail("\(method) replied \(String(describing: reply)), not a map", file: file, line: line)
      return [:]
    }
    return map
  }

  private let fixedVendor = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!

  private func plugin(
    history: Bool = true, status: PHAuthorizationStatus = .authorized, vendor: UUID?? = nil
  ) -> PhotoChangesPlugin {
    let id: UUID? = vendor ?? fixedVendor
    return PhotoChangesPlugin(
      historyAvailable: history, authorization: { status }, vendorIdentifier: { id })
  }

  private var hostHasPhotoAccess: Bool {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    return status == .authorized || status == .limited
  }

  // MARK: - channel

  func testChannelNameMatchesDart() {
    XCTAssertEqual(PhotoChangesPlugin.channelName, "dev.calorietracker/photochanges")
  }

  func testUnknownMethodIsNotImplemented() {
    let (reply, _) = call(plugin(), "nope")
    XCTAssertTrue((reply as AnyObject?) === FlutterMethodNotImplemented)
  }

  // MARK: - token archive

  /// The same archive/unarchive path the token takes, with a class every
  /// runtime can make (a PHPersistentChangeToken has no public init).
  func testArchiveRoundTripAndRejectsAnythingElse() throws {
    let uuid = NSUUID()
    let text = try XCTUnwrap(photoChangesArchive(uuid))
    XCTAssertNotNil(Data(base64Encoded: text), "base64")
    XCTAssertEqual(photoChangesUnarchive(text, as: NSUUID.self), uuid)
    // Another class, not base64, base64 of garbage, empty.
    XCTAssertNil(photoChangesUnarchive(text, as: NSDate.self))
    XCTAssertNil(photoChangesUnarchive("not base64 !!", as: NSUUID.self))
    XCTAssertNil(photoChangesUnarchive(Data("garbage".utf8).base64EncodedString(), as: NSUUID.self))
    XCTAssertNil(photoChangesUnarchive("", as: NSUUID.self))
  }

  func testRealTokenRoundTrip() throws {
    guard #available(iOS 16.0, *) else { throw XCTSkip("no change history before iOS 16") }
    guard hostHasPhotoAccess else { throw XCTSkip("the test host has no Photos access") }
    let token = PHPhotoLibrary.shared().currentChangeToken
    let text = try XCTUnwrap(photoChangesArchive(token))
    let restored = try XCTUnwrap(photoChangesUnarchiveToken(text))
    // The restored token reads history (Photos' own background work may
    // have changed something since, so no count is assumed).
    XCTAssertNoThrow(try PHPhotoLibrary.shared().fetchPersistentChanges(since: restored))
    XCTAssertNil(photoChangesUnarchiveToken(photoChangesArchive(NSUUID())!))
  }

  // MARK: - error mapping

  func testOnlyPhotosExpiredAndUnavailableResetTheToken() {
    if #available(iOS 16.0, *) {
      XCTAssertEqual(PHPhotosError.Code.persistentChangeTokenExpired.rawValue, 3105)
      XCTAssertEqual(PHPhotosError.Code.persistentChangeDetailsUnavailable.rawValue, 3210)
    }
    let expired = photoChangesStatus(for: NSError(domain: PHPhotosErrorDomain, code: 3105))
    XCTAssertEqual(expired.status, "expired")
    XCTAssertNil(expired.errorCode)
    let unavailable = photoChangesStatus(for: NSError(domain: PHPhotosErrorDomain, code: 3210))
    XCTAssertEqual(unavailable.status, "unavailable")
    XCTAssertNil(unavailable.errorCode)

    let other = photoChangesStatus(for: NSError(domain: PHPhotosErrorDomain, code: 3300))
    XCTAssertEqual(other.status, "error")
    XCTAssertEqual(other.errorCode, "\(PHPhotosErrorDomain):3300")
    // The code alone is not enough: another domain's 3105 is a plain error.
    let foreign = photoChangesStatus(for: NSError(domain: NSCocoaErrorDomain, code: 3105))
    XCTAssertEqual(foreign.status, "error")
    XCTAssertEqual(foreign.errorCode, "\(NSCocoaErrorDomain):3105")
    struct Odd: Error {}
    XCTAssertEqual(photoChangesStatus(for: Odd()).status, "error")
  }

  // MARK: - bounded read

  private struct FakeChange {
    let token: String
    let ids: Set<String>
    var fails = false
  }

  private struct Boom: Error {}

  private func collect(
    _ changes: [FakeChange], budget: TimeInterval = 1.0, maxChanges: Int = 5000,
    maxIdentifiers: Int = 10_000, tick: TimeInterval = 0, touched: inout [String]
  ) throws -> PhotoChangesCollection<String> {
    var now: TimeInterval = 100
    var seen: [String] = []
    defer { touched = seen }
    return try photoChangesCollect(
      changes, budget: budget, maxChanges: maxChanges, maxIdentifiers: maxIdentifiers,
      clock: {
        defer { now += tick }
        return now
      },
      token: { $0.token },
      inserted: {
        seen.append($0.token)
        if $0.fails { throw Boom() }
        return $0.ids
      })
  }

  private let four = [
    FakeChange(token: "t1", ids: ["a"]),
    FakeChange(token: "t2", ids: ["b", "x"]),
    FakeChange(token: "t3", ids: ["c"]),
    FakeChange(token: "t4", ids: ["d"]),
  ]

  func testCollectReadsEverythingWithinTheBudget() throws {
    var touched: [String] = []
    let out = try collect(four, touched: &touched)
    XCTAssertEqual(out.inserted, ["a", "b", "x", "c", "d"])
    XCTAssertEqual(out.lastToken, "t4")
    XCTAssertEqual(out.processed, 4)
    XCTAssertFalse(out.truncated)
  }

  func testCollectStopsAtTheBudgetWithTheLastProcessedToken() throws {
    var touched: [String] = []
    // The clock reads 0.4 s later on every call: start 0, then 0.4 and 0.8
    // before t2 and t3, and 1.2 ≥ 1.0 before t4, which is left unread.
    let out = try collect(four, budget: 1.0, tick: 0.4, touched: &touched)
    XCTAssertTrue(out.truncated)
    XCTAssertEqual(out.lastToken, "t3")
    XCTAssertEqual(out.processed, 3)
    XCTAssertEqual(out.inserted, ["a", "b", "x", "c"])
    XCTAssertEqual(touched, ["t1", "t2", "t3"], "t4 must not be read")
  }

  func testCollectAlwaysProcessesOneChangeEvenWithNoBudgetLeft() throws {
    var touched: [String] = []
    let out = try collect(four, budget: -5, tick: 10, touched: &touched)
    XCTAssertTrue(out.truncated)
    XCTAssertEqual(out.lastToken, "t1")
    XCTAssertEqual(out.processed, 1)
    XCTAssertEqual(touched, ["t1"])
  }

  func testCollectStopsAtMaxChangesAndMaxIdentifiers() throws {
    var touched: [String] = []
    let byChanges = try collect(four, maxChanges: 2, touched: &touched)
    XCTAssertTrue(byChanges.truncated)
    XCTAssertEqual(byChanges.lastToken, "t2")
    XCTAssertEqual(touched, ["t1", "t2"])

    // Three IDs gathered after t2 ≥ 3: t3 is left for the next read.
    let byIds = try collect(four, maxIdentifiers: 3, touched: &touched)
    XCTAssertTrue(byIds.truncated)
    XCTAssertEqual(byIds.lastToken, "t2")
    XCTAssertEqual(byIds.inserted, ["a", "b", "x"])

    // Exactly at the limit with nothing left over is not truncated.
    let exact = try collect(Array(four.prefix(2)), maxChanges: 2, touched: &touched)
    XCTAssertFalse(exact.truncated)
    XCTAssertEqual(exact.lastToken, "t2")
  }

  func testCollectOfNoChangesHasNoToken() throws {
    var touched: [String] = []
    let out = try collect([], tick: 1, touched: &touched)
    XCTAssertNil(out.lastToken)
    XCTAssertEqual(out.processed, 0)
    XCTAssertFalse(out.truncated)
    XCTAssertTrue(out.inserted.isEmpty)
  }

  /// A change whose details cannot be read ends the read with the error:
  /// the caller's token still covers it, so it is retried, never skipped.
  func testCollectRethrowsAndReadsNothingAfterAFailingChange() {
    var changes = four
    changes[1].fails = true
    var touched: [String] = []
    XCTAssertThrowsError(try collect(changes, touched: &touched)) { error in
      XCTAssertTrue(error is Boom)
    }
    XCTAssertEqual(touched, ["t1", "t2"])
  }

  // MARK: - device tag

  func testDeviceTagIsEightHexAndStable() {
    let tag = photoChangesDeviceTag(fixedVendor)
    // SHA-256("E621E1F8-C36C-495A-93FC-0C247A3E6E5F"), first 4 bytes.
    XCTAssertEqual(tag, "94996017")
    XCTAssertEqual(photoChangesDeviceTag(fixedVendor), tag)
    XCTAssertEqual(
      photoChangesDeviceTag(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!),
      "12b9377c")
    XCTAssertNil(photoChangesDeviceTag(nil))

    let real = photoChangesDeviceTag(UIDevice.current.identifierForVendor)
    XCTAssertNotNil(real)
    XCTAssertNotNil(real?.range(of: "^[0-9a-f]{8}$", options: .regularExpression))
    XCTAssertEqual(photoChangesDeviceTag(UIDevice.current.identifierForVendor), real)
  }

  // MARK: - branches that never touch the library

  func testUnsupportedBeforeIOS16() {
    let p = plugin(history: false)
    let token = map(p, "currentToken")
    XCTAssertEqual(token["status"] as? String, "unsupported")
    XCTAssertNil(token["token"])
    let since = map(p, "insertedImagesSince", ["token": "abc", "limit": 50])
    XCTAssertEqual(since["status"] as? String, "unsupported")
    XCTAssertNil(since["token"])
    XCTAssertEqual((since["ids"] as? [Any])?.count, 0)
    XCTAssertEqual(since["truncated"] as? Bool, false)
    // Album lookups do not need change history.
    let albums = map(p, "albumAssetIds", ["titles": [String](), "sinceMs": 0, "limit": 10])
    XCTAssertEqual(albums["status"] as? String, "ok")
    XCTAssertEqual((albums["ids"] as? [Any])?.count, 0)
  }

  /// Without access it answers denied — it never asks (no prompt from a
  /// background run) and never reads.
  func testDeniedWithoutAccessAndNeverPrompts() {
    for status in [PHAuthorizationStatus.notDetermined, .denied, .restricted] {
      let p = plugin(status: status)
      XCTAssertEqual(map(p, "currentToken")["status"] as? String, "denied", "\(status.rawValue)")
      let since = map(p, "insertedImagesSince", ["token": "abc"])
      XCTAssertEqual(since["status"] as? String, "denied")
      XCTAssertNil(since["token"])
      XCTAssertEqual(since["device_tag"] as? String, "94996017")
      let albums = map(p, "albumAssetIds", ["titles": ["Meta AI"], "sinceMs": 0, "limit": 10])
      XCTAssertEqual(albums["status"] as? String, "denied")
      XCTAssertEqual((albums["ids"] as? [Any])?.count, 0)
    }
  }

  /// No identifierForVendor yet (after a restart, before the first unlock):
  /// nothing can be tied to this phone, so nothing changes.
  func testNoDeviceTagIsAnErrorThatKeepsTheToken() {
    let p = plugin(vendor: .some(nil))
    let token = map(p, "currentToken")
    XCTAssertEqual(token["status"] as? String, "error")
    XCTAssertEqual(token["error_code"] as? String, "no_device_tag")
    XCTAssertNil(token["token"])
    let since = map(p, "insertedImagesSince", ["token": "abc"])
    XCTAssertEqual(since["status"] as? String, "error")
    XCTAssertEqual(since["error_code"] as? String, "no_device_tag")
    XCTAssertEqual(since["token"] as? String, "abc")
    XCTAssertNil(since["device_tag"])
  }

  // MARK: - arguments

  func testInsertedImagesArgumentsAreClamped() {
    let defaults = InsertedImagesRequest([:])
    XCTAssertNil(defaults.token)
    XCTAssertEqual(defaults.limit, 200)
    XCTAssertEqual(defaults.budget, 1.0, accuracy: 0.0001)
    XCTAssertEqual(defaults.maxChanges, 5000)

    let high = InsertedImagesRequest([
      "token": "  t  ", "limit": 10_000, "budget_ms": 99_999, "max_changes": 1_000_000,
    ])
    XCTAssertEqual(high.token, "t")
    XCTAssertEqual(high.limit, 500)
    XCTAssertEqual(high.budget, 1.5, accuracy: 0.0001)
    XCTAssertEqual(high.maxChanges, 5000)

    let low = InsertedImagesRequest([
      "token": "   ", "limit": -3, "budget_ms": 0, "max_changes": 0,
    ])
    XCTAssertNil(low.token)
    XCTAssertEqual(low.limit, 1)
    XCTAssertEqual(low.budget, 0.05, accuracy: 0.0001)
    XCTAssertEqual(low.maxChanges, 1)

    let wrongTypes = InsertedImagesRequest(["token": 5, "limit": "9", "budget_ms": "x"])
    XCTAssertNil(wrongTypes.token)
    XCTAssertEqual(wrongTypes.limit, 200)
    XCTAssertEqual(wrongTypes.budget, 1.0, accuracy: 0.0001)
  }

  func testAlbumArgumentsAndTitleMatching() {
    let request = AlbumRequest([
      "titles": [" Meta AI ", "", 7, String(repeating: "x", count: 65), "Ray-Ban Meta"],
      "sinceMs": 1_700_000_000_000, "limit": 5000,
    ])
    XCTAssertEqual(request.titles, ["Meta AI", "Ray-Ban Meta"])
    XCTAssertEqual(request.since.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
    XCTAssertEqual(request.limit, 1000)
    XCTAssertEqual(AlbumRequest([:]).since.timeIntervalSince1970, 0)
    XCTAssertEqual(AlbumRequest([:]).limit, 500)

    XCTAssertTrue(photoChangesTitleMatches("meta ai", request.titles))
    XCTAssertTrue(photoChangesTitleMatches("  META AI\n", request.titles))
    XCTAssertTrue(photoChangesTitleMatches("ray-ban meta", request.titles))
    XCTAssertFalse(photoChangesTitleMatches("Meta AI 2", request.titles))
    XCTAssertFalse(photoChangesTitleMatches("", request.titles))
    XCTAssertFalse(photoChangesTitleMatches(nil, request.titles))
  }

  // MARK: - the real library (when the test host has Photos access)

  func testRealLibraryFreshOkAndUnreadable() throws {
    guard #available(iOS 16.0, *) else { throw XCTSkip("no change history before iOS 16") }
    guard hostHasPhotoAccess else { throw XCTSkip("the test host has no Photos access") }
    let p = PhotoChangesPlugin()

    let current = map(p, "currentToken")
    XCTAssertEqual(current["status"] as? String, "ok")
    let token = try XCTUnwrap(current["token"] as? String)
    XCTAssertNotNil(photoChangesUnarchiveToken(token))
    let tag = try XCTUnwrap(current["device_tag"] as? String)
    XCTAssertEqual(tag, photoChangesDeviceTag(UIDevice.current.identifierForVendor))

    let fresh = map(p, "insertedImagesSince", ["limit": 10])
    XCTAssertEqual(fresh["status"] as? String, "fresh")
    XCTAssertNotNil(photoChangesUnarchiveToken(try XCTUnwrap(fresh["token"] as? String)))
    XCTAssertEqual((fresh["ids"] as? [Any])?.count, 0)

    let ok = map(p, "insertedImagesSince", ["token": token, "limit": 10])
    XCTAssertEqual(ok["status"] as? String, "ok")
    XCTAssertNotNil(ok["token"] as? String)
    XCTAssertEqual(ok["device_tag"] as? String, tag)
    XCTAssertNotNil(ok["truncated"] as? Bool)
    XCTAssertNotNil(ok["dropped"] as? Int)
    XCTAssertNotNil(ok["ids"] as? [[String: Any]])

    let unreadable = map(p, "insertedImagesSince", ["token": "AAAA", "limit": 10])
    XCTAssertEqual(unreadable["status"] as? String, "unavailable")
    XCTAssertEqual(unreadable["error_code"] as? String, "token_unreadable")
    XCTAssertNotNil(photoChangesUnarchiveToken(try XCTUnwrap(unreadable["token"] as? String)))
  }
}

/// `scripts/run_e2e_ios.sh --scenario late_import_native` (design G1a):
/// the script adds a HEIC whose EXIF capture time is two days old with
/// `simctl addmedia` while this test waits. insertedImagesSince must
/// report it; the watcher's createDate > cutoff query must not. Skipped
/// unless the script set BITEWISE_SCENARIO (xcodebuild passes TEST_RUNNER_
/// variables through).
class LateImportNativeScenarioTests: XCTestCase {
  private var env: [String: String] { ProcessInfo.processInfo.environment }

  private func call(_ plugin: PhotoChangesPlugin, _ method: String, _ args: Any?) -> [String: Any] {
    let replied = expectation(description: method)
    var reply: Any?
    plugin.handle(FlutterMethodCall(methodName: method, arguments: args)) {
      reply = $0
      replied.fulfill()
    }
    wait(for: [replied], timeout: 30)
    return reply as? [String: Any] ?? [:]
  }

  private func filename(of id: String) -> String? {
    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    else { return nil }
    return PHAssetResource.assetResources(for: asset).first?.originalFilename
  }

  func testInsertedImagesSinceSeesALateImportTheCreateDateQueryMisses() throws {
    guard env["BITEWISE_SCENARIO"] == "late_import_native",
      let expectedName = env["BITEWISE_SCENARIO_FILE"], !expectedName.isEmpty
    else { throw XCTSkip("run by scripts/run_e2e_ios.sh --scenario late_import_native") }
    guard #available(iOS 16.0, *) else { throw XCTSkip("no change history before iOS 16") }

    // The script writes the Photos grant once this process is up.
    var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    let grantDeadline = Date().addingTimeInterval(60)
    while status != .authorized && Date() < grantDeadline {
      Thread.sleep(forTimeInterval: 0.5)
      status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }
    XCTAssertEqual(status, .authorized, "no Photos access (TCC grant)")
    guard status == .authorized else { return }

    let plugin = PhotoChangesPlugin()
    let start = call(plugin, "currentToken", nil)
    XCTAssertEqual(start["status"] as? String, "ok")
    let token = try XCTUnwrap(start["token"] as? String)
    let cutoff = Date().addingTimeInterval(-60)

    // Tell the script to add the photo now.
    let marker = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("bitewise_late_import_ready_\(expectedName)")
    try Data().write(to: marker)
    defer { try? FileManager.default.removeItem(at: marker) }

    // Read the way the app will: carry on from each reply's token. The
    // import makes Photos busy, so a read can stop at its budget
    // (truncated) and the next one resumes where it stopped.
    var cursor = token
    var found: [String: Any]?
    var truncatedReads = 0
    var last: [String: Any] = [:]
    let deadline = Date().addingTimeInterval(180)
    while Date() < deadline {
      let readStart = Date()
      last = call(plugin, "insertedImagesSince", ["token": cursor, "limit": 500])
      print(
        "late_import_native: read \(Int(Date().timeIntervalSince(readStart) * 1000)) ms,"
          + " truncated=\(last["truncated"] ?? "-"), ids=\((last["ids"] as? [Any])?.count ?? -1)")
      XCTAssertEqual(last["status"] as? String, "ok")
      XCTAssertEqual(
        last["device_tag"] as? String,
        photoChangesDeviceTag(UIDevice.current.identifierForVendor))
      guard last["status"] as? String == "ok", let next = last["token"] as? String else { break }
      cursor = next
      let ids = last["ids"] as? [[String: Any]] ?? []
      if found == nil {
        found = ids.first { ($0["id"] as? String).flatMap(filename(of:)) == expectedName }
      }
      let truncated = last["truncated"] as? Bool ?? false
      if truncated { truncatedReads += 1 }
      if found != nil && !truncated { break }
      if !truncated { Thread.sleep(forTimeInterval: 1) }
    }
    print("late_import_native: \(truncatedReads) truncated read(s) before the end of history")
    XCTAssertEqual(last["dropped"] as? Int, 0)
    let entry = try XCTUnwrap(found, "insertedImagesSince never reported \(expectedName)")
    let id = try XCTUnwrap(entry["id"] as? String)

    // Dated at capture, two days back — so a date query cannot see it.
    let asset = try XCTUnwrap(
      PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject)
    let created = try XCTUnwrap(asset.creationDate)
    XCTAssertLessThan(created, cutoff.addingTimeInterval(-86_400), "creationDate \(created)")
    XCTAssertEqual(
      (entry["created_ms"] as? NSNumber)?.int64Value, photoChangesMillis(created))
    if #available(iOS 26.0, *), let added = asset.addedDate {
      XCTAssertEqual((entry["added_ms"] as? NSNumber)?.int64Value, photoChangesMillis(added))
      XCTAssertGreaterThan(added, cutoff)
    }

    // The watcher's query shape (createDate after the cutoff) misses it.
    let options = PHFetchOptions()
    options.predicate = NSPredicate(format: "creationDate > %@", cutoff as NSDate)
    var byDate = Set<String>()
    PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { a, _, _ in
      byDate.insert(a.localIdentifier)
    }
    XCTAssertFalse(byDate.contains(id), "a createDate > cutoff query found the late import")

    // And the token handed back moves past it: asked again, it is gone.
    let again = call(plugin, "insertedImagesSince", ["token": cursor, "limit": 500])
    XCTAssertEqual(again["status"] as? String, "ok")
    let againIds = (again["ids"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    XCTAssertFalse(againIds.contains(id))
  }
}
