import Flutter
import UIKit
import XCTest

@testable import Runner

/// The Meta glasses bridge (Runner/MetaDatPlugin.swift, feat/meta-dat
/// prototype) against DAT's Mock Device Kit: simulated Ray-Ban Meta
/// glasses, no hardware, no Meta AI app. Everything is observed the way
/// Dart sees it: the status map and the emitted event maps.
@MainActor
final class MetaDatControllerTests: XCTestCase {

  private var events: [[String: Any]] = []
  private var controller: MetaDatController!

  override func setUp() async throws {
    try await super.setUp()
    events = []
    controller = MetaDatController { [weak self] event in
      self?.events.append(event)
    }
  }

  override func tearDown() async throws {
    if controller.configured {
      await controller.disableMock()
    }
    controller = nil
    try await super.tearDown()
  }

  private func waitFor(
    _ what: String, timeout: TimeInterval = 15, _ predicate: () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() {
      if Date() > deadline {
        XCTFail("timed out waiting for \(what); events: \(eventSummary())")
        throw XCTSkip("timed out: \(what)")
      }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  private func eventSummary() -> String {
    events.map { e in
      let type = e["type"] as? String ?? "?"
      let detail = (e["state"] ?? e["press"] ?? e["code"] ?? e["count"]).map { "\($0)" } ?? ""
      return "\(type):\(detail)"
    }.joined(separator: ", ")
  }

  private func has(_ type: String, _ key: String, _ value: String) -> Bool {
    events.contains { $0["type"] as? String == type && $0[key] as? String == value }
  }

  // MARK: - before configure

  /// Registering the plugin must not initialise the SDK: until Dart asks,
  /// status reads nothing from Wearables.shared and every action refuses.
  func testNothingTouchesTheSdkBeforeConfigure() {
    let s = controller.status()
    XCTAssertEqual(s["supported"] as? Bool, true)
    XCTAssertEqual(s["configured"] as? Bool, false)
    XCTAssertEqual(s["registration"] as? String, "unknown")
    XCTAssertEqual(s["devices"] as? Int, 0)
    XCTAssertEqual(s["session"] as? String, "idle")
    XCTAssertEqual(s["camera"] as? String, "stopped")
    XCTAssertEqual(s["mockAvailable"] as? Bool, true)  // tests run Debug
    XCTAssertThrowsError(try controller.startSession()) { error in
      XCTAssertEqual((error as? MetaDatFailure)?.code, "not_configured")
    }
    XCTAssertThrowsError(try controller.enableMock(photo: nil)) { error in
      XCTAssertEqual((error as? MetaDatFailure)?.code, "not_configured")
    }
    XCTAssertFalse(controller.capture(resolution: nil, quality: nil))
    XCTAssertFalse(controller.mockCapturePress("shortPress"))
    XCTAssertTrue(events.isEmpty)
  }

  func testFailuresKeepTheirWireCode() {
    let error = MetaDatPlugin.flutterError(MetaDatFailure("session", "noEligibleDevice"))
    XCTAssertEqual(error.code, "session")
    XCTAssertEqual(error.message, "noEligibleDevice")
    XCTAssertEqual(MetaDatPlugin.channelName, "dev.calorietracker/metadat")
  }

  func testTheMockFixtureIsAJpeg() {
    let jpeg = MetaDatMockFixture.plateJpeg(width: 64, height: 48)
    XCTAssertEqual(Array(jpeg.prefix(3)), [0xFF, 0xD8, 0xFF])
    let image = UIImage(data: jpeg)
    XCTAssertEqual(image?.size, CGSize(width: 64, height: 48))
  }

  // MARK: - end to end on Mock Device Kit

  /// configure → mock glasses → session → camera started → capture →
  /// the fixture's exact bytes reach "Dart"; the capture button arrives
  /// as a button event; stop ends it all.
  func testMockGlassesSessionCapturesAndReportsTheShutter() async throws {
    let status = try controller.configure()
    XCTAssertEqual(status["configured"] as? Bool, true)
    // A second configure is a no-op, not an error.
    XCTAssertEqual(try controller.configure()["configured"] as? Bool, true)
    // No glasses yet: no session, and a code Dart can word.
    XCTAssertEqual(controller.status()["activeDevice"] as? Bool, false)
    XCTAssertThrowsError(try controller.startSession()) { error in
      XCTAssertEqual((error as? MetaDatFailure)?.code, "no_device")
    }

    let fixture = MetaDatMockFixture.plateJpeg(width: 320, height: 240)
    try controller.enableMock(photo: fixture)
    XCTAssertEqual(controller.status()["mock"] as? Bool, true)
    try await waitFor("a registered mock device") {
      let s = controller.status()
      return s["registration"] as? String == "registered" && (s["devices"] as? Int ?? 0) > 0
    }
    // The selector must pick the glasses before DAT allows a session.
    try await waitFor("the active device") { controller.hasActiveDevice }
    XCTAssertTrue(
      events.contains { $0["type"] as? String == "activeDevice" && $0["active"] as? Bool == true })
    XCTAssertEqual(controller.status()["activeDevice"] as? Bool, true)

    try controller.startSession()
    try controller.startSession()  // idempotent while one is running
    try await waitFor("the session to start") { has("session", "state", "started") }
    try await waitFor("the photo capability") { has("camera", "state", "started") }
    XCTAssertEqual(controller.status()["session"] as? String, "started")

    XCTAssertTrue(controller.capture(resolution: "large", quality: "high"))
    XCTAssertTrue(controller.captureInFlight)
    // One capture in flight at most: results carry no request id.
    XCTAssertFalse(controller.capture(resolution: nil, quality: nil))
    try await waitFor("the captured photo") {
      events.contains { $0["type"] as? String == "photo" }
    }
    let photo = events.first { $0["type"] as? String == "photo" }!
    // The bridge hands over the image bytes as the toolkit delivered them.
    // (Mock Device Kit re-encodes its fixture, so compare the picture, not
    // the bytes: a JPEG of the fixture's size.)
    let bytes = (photo["bytes"] as? FlutterStandardTypedData)?.data ?? Data()
    XCTAssertEqual(Array(bytes.prefix(3)), [0xFF, 0xD8, 0xFF])
    XCTAssertEqual(UIImage(data: bytes)?.size, CGSize(width: 320, height: 240))
    let receivedAt = (photo["receivedAtMs"] as? Int64).map {
      Date(timeIntervalSince1970: Double($0) / 1000)
    }
    XCTAssertNotNil(receivedAt)
    XCTAssertLessThan(abs(receivedAt!.timeIntervalSinceNow), 120)
    XCTAssertFalse(controller.captureInFlight)

    // The capture button: Inputs activates asynchronously after the
    // session starts and an early press is dropped, so press until one
    // lands.
    var pressed = false
    for _ in 0..<10 where !pressed {
      XCTAssertTrue(controller.mockCapturePress("shortPress"))
      let deadline = Date().addingTimeInterval(1.5)
      while Date() < deadline && !pressed {
        pressed = has("button", "press", "shortPress")
        try await Task.sleep(nanoseconds: 100_000_000)
      }
    }
    XCTAssertTrue(pressed, "no button event; events: \(eventSummary())")

    controller.stopSession()
    XCTAssertTrue(has("session", "state", "stopped"))
    XCTAssertEqual(controller.status()["camera"] as? String, "stopped")
    XCTAssertFalse(controller.capture(resolution: nil, quality: nil))
  }
}

/// A binary messenger that records what the plugin sends to Dart.
private final class RecordingMessenger: NSObject, FlutterBinaryMessenger {
  var sent: [(channel: String, message: Data?)] = []

  func send(onChannel channel: String, message: Data?) {
    sent.append((channel, message))
  }

  func send(
    onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply? = nil
  ) {
    sent.append((channel, message))
    callback?(nil)
  }

  func setMessageHandlerOnChannel(
    _ channel: String, binaryMessageHandler handler: FlutterBinaryMessageHandler? = nil
  ) -> FlutterBinaryMessengerConnection {
    0
  }

  func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {}
}

/// The plugin as registered: events must reach Dart through its channel.
/// The first simulator run showed none did — the registrar never retains
/// the channel object, and the plugin only held it weakly.
@MainActor
final class MetaDatPluginChannelTests: XCTestCase {

  func testThePluginKeepsItsChannelAndEventsGoThroughIt() async throws {
    let messenger = RecordingMessenger()
    weak var weakChannel: FlutterMethodChannel?
    var plugin: MetaDatPlugin?
    autoreleasepool {
      let channel = FlutterMethodChannel(
        name: MetaDatPlugin.channelName, binaryMessenger: messenger)
      weakChannel = channel
      plugin = MetaDatPlugin(channel: channel)
    }
    XCTAssertNotNil(weakChannel, "the plugin must own its channel")
    XCTAssertTrue(plugin?.channel === weakChannel)

    // Real events: Mock Device Kit glasses report registration and devices.
    let controller = plugin!.controller
    _ = try controller.configure()
    try controller.enableMock(photo: nil)
    let deadline = Date().addingTimeInterval(15)
    var types: [String] = []
    while Date() < deadline {
      types = messenger.sent.compactMap { sent in
        guard sent.channel == MetaDatPlugin.channelName, let data = sent.message
        else { return nil }
        let call = FlutterStandardMethodCodec.sharedInstance().decodeMethodCall(data)
        guard call.method == "event" else { return nil }
        return (call.arguments as? [String: Any])?["type"] as? String
      }
      if types.contains("activeDevice") { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    await controller.disableMock()
    XCTAssertTrue(
      types.contains("activeDevice"), "no event reached the channel; got \(types)")
  }
}
