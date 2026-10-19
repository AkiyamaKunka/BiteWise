import Flutter
import ImageIO
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
