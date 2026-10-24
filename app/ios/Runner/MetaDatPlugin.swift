import Flutter
import MWDATCamera
import MWDATCore
import MWDATInputs
import UIKit

#if METADAT_MOCK
  import MWDATMockDevice
#endif

/// Meta glasses bridge: the Meta Wearables Device Access Toolkit (DAT,
/// github.com/facebook/meta-wearables-dat-ios, pinned 1.0.1).
///
/// PROTOTYPE, branch feat/meta-dat only (docs/META_DAT.md). Standalone
/// photo capture and Inputs are EXPERIMENTAL in DAT 1.0: usable in
/// development and beta, not publishable. The SDK needs iOS 17.2, which is
/// why this branch alone raises the deployment target.
///
/// The SDK is NEVER initialised by registering this plugin. Only the
/// flag-gated Dart "Glasses session" screen calls `configure`, and the
/// plugin is registered for the app's own engine only, never for the
/// headless background engine: that engine never shows the screen, so it
/// has no use for a session. (When a session ends is the screen's call
/// and DAT's: Bitewise keeps one through a phone lock for a while, and
/// DAT stops it on a fold. Whether DAT also stops it while the phone is
/// locked is open question 4 in docs/META_DAT.md.)
///
/// Channel `dev.calorietracker/metadat`. Dart → native:
///   status                       → status map (below); safe before configure
///   configure                    → status map; Wearables.configure() once
///   register / unregister        → nil; hands over to the Meta AI app
///   handleUrl {url}              → Bool; the Meta AI callback link
///   requestCameraPermission      → 'granted' | 'denied'
///   startSession / stopSession   → nil; the session reports its states
///   capture {resolution, quality}→ Bool; false while not ready or busy
///   openGlassesAppUpdate         → nil; Meta AI's update page for the
///                                  toolkit's app on the glasses
///   enableMock {photo?}          → nil; Debug config only (METADAT_MOCK)
///   mockCapturePress {press}     → Bool; Debug only, a shutter-button press
/// Native → Dart: method `event` with one map, `type` first:
///   registration {state} · devices {count} · activeDevice {active} ·
///   session {state} · camera {state} · progress {fraction} ·
///   button {press} · photo {bytes, receivedAtMs} · error {code, message}
/// Error codes come from [MetaDatWire] (sessionError, photoError) and the
/// controller. `session_version_warning` is the only one that does not
/// mean something stopped: DAT lets that session go on.
/// Status map: supported, configured, registration, devices, activeDevice,
/// session, camera, mock, mockAvailable. Every value is a wire string from
/// [MetaDatWire]; lib/services/glasses/meta_dat_channel.dart reads them.
final class MetaDatPlugin: NSObject, FlutterPlugin {
  static let channelName = "dev.calorietracker/metadat"

  let controller: MetaDatController

  /// Held here: the registrar keeps only the call handler (and through it
  /// this plugin), never the channel object. Without this reference the
  /// channel was freed right after register() and every event went to a
  /// nil channel — Dart saw no session, photo or button at all
  /// (simulator, 2026-10-23).
  let channel: FlutterMethodChannel

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    // Channel calls arrive on the main thread, and the controller emits
    // only from the main actor: invokeMethod is always on the main thread.
    // Weak: the plugin owns the channel; no cycle through the controller.
    controller = MainActor.assumeIsolated {
      MetaDatController { [weak channel] event in
        channel?.invokeMethod("event", arguments: event)
      }
    }
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(MetaDatPlugin(channel: channel), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    MainActor.assumeIsolated {
      let c = controller
      switch call.method {
      case "status":
        result(c.status())
      case "configure":
        do {
          result(try c.configure())
        } catch {
          result(MetaDatPlugin.flutterError(error))
        }
      case "register":
        Task { @MainActor in
          do {
            try await c.register()
            result(nil)
          } catch {
            result(MetaDatPlugin.flutterError(error))
          }
        }
      case "unregister":
        Task { @MainActor in
          do {
            try await c.unregister()
            result(nil)
          } catch {
            result(MetaDatPlugin.flutterError(error))
          }
        }
      case "handleUrl":
        guard let raw = args["url"] as? String, let url = URL(string: raw) else {
          result(FlutterError(code: "bad_args", message: "url missing", details: nil))
          return
        }
        Task { @MainActor in
          do {
            result(try await c.handleUrl(url))
          } catch {
            result(MetaDatPlugin.flutterError(error))
          }
        }
      case "requestCameraPermission":
        Task { @MainActor in
          do {
            result(try await c.requestCameraPermission())
          } catch {
            result(MetaDatPlugin.flutterError(error))
          }
        }
      case "startSession":
        do {
          try c.startSession()
          result(nil)
        } catch {
          result(MetaDatPlugin.flutterError(error))
        }
      case "stopSession":
        c.stopSession()
        result(nil)
      case "capture":
        result(
          c.capture(
            resolution: args["resolution"] as? String, quality: args["quality"] as? String))
      case "openGlassesAppUpdate":
        Task { @MainActor in
          do {
            try await c.openGlassesAppUpdate()
            result(nil)
          } catch {
            result(MetaDatPlugin.flutterError(error))
          }
        }
      case "enableMock":
        #if METADAT_MOCK
          do {
            try c.enableMock(photo: (args["photo"] as? FlutterStandardTypedData)?.data)
            result(nil)
          } catch {
            result(MetaDatPlugin.flutterError(error))
          }
        #else
          result(
            FlutterError(
              code: "unsupported", message: "Mock glasses exist only in debug builds.",
              details: nil))
        #endif
      case "mockCapturePress":
        #if METADAT_MOCK
          result(c.mockCapturePress(args["press"] as? String ?? "shortPress"))
        #else
          result(false)
        #endif
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Every failure reaches Dart as a PlatformException with a stable code.
  /// Messages are the SDK's own case descriptions: they never carry the
  /// app ID, client token or any other configuration value.
  static func flutterError(_ error: Error) -> FlutterError {
    let f = error as? MetaDatFailure ?? MetaDatFailure("internal", String(describing: error))
    return FlutterError(code: f.code, message: f.message, details: nil)
  }
}

/// A failure with a stable wire code (the Dart side switches on it).
struct MetaDatFailure: Error, Equatable {
  let code: String
  let message: String
  init(_ code: String, _ message: String) {
    self.code = code
    self.message = message
  }
}

/// SDK values → the channel's wire strings, and back. Pure, so RunnerTests
/// pins them without glasses.
enum MetaDatWire {
  static func registration(_ s: RegistrationState) -> String {
    switch s {
    case .unavailable: return "unavailable"
    case .available: return "available"
    case .registering: return "registering"
    case .registered: return "registered"
    }
  }

  static func session(_ s: DeviceSessionState) -> String {
    switch s {
    case .idle: return "idle"
    case .starting: return "starting"
    case .started: return "started"
    case .paused: return "paused"
    case .stopping: return "stopping"
    case .stopped: return "stopped"
    }
  }

  static func camera(_ s: PhotoState) -> String {
    switch s {
    case .stopped: return "stopped"
    case .starting: return "starting"
    case .started: return "started"
    case .stopping: return "stopping"
    @unknown default: return "unknown"
    }
  }

  static func press(_ p: MWDATInputs.CapturePressType) -> String {
    switch p {
    case .shortPress: return "shortPress"
    case .hold: return "hold"
    case .doublePress: return "doublePress"
    }
  }

  static func permission(_ s: PermissionStatus) -> String {
    switch s {
    case .granted: return "granted"
    case .denied: return "denied"
    @unknown default: return "denied"
    }
  }

  /// Meta's version-dependencies guide: handle each DeviceSessionError on
  /// its own, they are not equally recoverable. Only
  /// insufficientSDKVersion needs a new Bitewise build; only
  /// dwaOutOfStuRange lets the session go on; datAppOnTheGlassesUpdateRequired
  /// is fixed in the Meta AI app (openDATGlassesAppUpdate); dwaUnavailable
  /// means the toolkit's app on the glasses did not come up (not installed:
  /// its install fails below 10 % battery, a known issue).
  static func sessionError(_ e: DeviceSessionError) -> String {
    switch e {
    case .noEligibleDevice: return "no_device"
    case .datAppOnTheGlassesUpdateRequired: return "session_update_glasses_app"
    case .insufficientSDKVersion: return "session_sdk_too_old"
    case .dwaOutOfStuRange: return versionWarning
    case .dwaUnavailable: return "session_glasses_app_unavailable"
    case .thermalCritical, .thermalEmergency: return "session_thermal"
    case .batteryCritical, .peakPowerShutdown: return "session_battery"
    case .sessionAlreadyStopped, .sessionAlreadyExists, .sessionIdle,
      .capabilityAlreadyActive, .capabilityNotFound, .unexpectedError:
      return "session"
    @unknown default: return "session"
    }
  }

  /// The one session error that stops nothing (Meta: "Not blocking. The
  /// session can continue").
  static let versionWarning = "session_version_warning"

  static func photoError(_ e: PhotoError) -> String {
    switch e {
    case .notReady: return "photo_not_ready"
    case .captureFailure: return "photo_capture_failed"
    case .sessionSetupFailed: return "photo_setup_failed"
    case .busy: return "photo_busy"
    case .serviceUnavailable: return "photo_unavailable"
    case .permissionDenied: return "photo_permission_denied"
    case .deviceHealthCritical: return "photo_device_health"
    case .deviceDisconnected: return "photo_disconnected"
    @unknown default: return "photo_error"
    }
  }

  /// Unknown or missing → `.large` (1080p class): plenty for a food photo,
  /// and far faster over the Bluetooth Classic link than `.full`
  /// (4032×3024), whose transfer can hit the 30 s silence timeout.
  static func resolution(_ raw: String?) -> PhotoResolution {
    switch raw {
    case "small": return .small
    case "medium": return .medium
    case "full": return .full
    default: return .large
    }
  }

  static func quality(_ raw: String?) -> PhotoQuality {
    switch raw {
    case "low": return .low
    case "medium": return .medium
    default: return .high
    }
  }
}

/// Starting the photo capability, as Meta's camera-capture guide prescribes
/// ("Capture reliability"): startup is the most common failure point, and
/// the attempt after an intermittent sessionSetupFailed usually works. So
/// a startup is watched until `.started`; a fall back to `.stopped` after
/// `.starting`, a sessionSetupFailed or the startup timeout each fail it;
/// the first failure asks for a retry on a FRESH camera (a stopped one is
/// invalidated), and only a failed retry is reported. Reaching `.started`
/// resets the count. Pure, so RunnerTests pins it without glasses.
struct MetaDatPhotoStartup: Equatable {
  enum Action: Equatable {
    /// No verdict: keep waiting (or nothing is starting).
    case nothing
    /// Stop this camera and start a fresh one.
    case retry
    /// Stop this camera and report photo_setup_failed.
    case fail
  }

  static let maxRetries = 1

  /// Retries spent on the current startup; back to 0 at `.started`.
  private(set) var retries = 0
  /// A camera was added and asked to start, and has not reached
  /// `.started` (or failed) yet.
  private(set) var pending = false
  private var sawStarting = false

  /// A camera was added and `photo.start()` called.
  mutating func began() {
    pending = true
    sawStarting = false
  }

  mutating func on(_ state: PhotoState) -> Action {
    guard pending else { return .nothing }
    switch state {
    case .starting:
      sawStarting = true
      return .nothing
    case .started:
      pending = false
      sawStarting = false
      retries = 0
      return .nothing
    case .stopped:
      // The initial `.stopped` of a photo not yet started is no verdict.
      return sawStarting ? failed() : .nothing
    case .stopping:
      return .nothing
    @unknown default:
      return .nothing
    }
  }

  mutating func setupFailed() -> Action { pending ? failed() : .nothing }

  mutating func timedOut() -> Action { pending ? failed() : .nothing }

  /// The camera goes for another reason (session stopped or paused).
  mutating func reset() {
    pending = false
    sawStarting = false
    retries = 0
  }

  private mutating func failed() -> Action {
    pending = false
    sawStarting = false
    if retries < Self.maxRetries {
      retries += 1
      return .retry
    }
    retries = 0
    return .fail
  }
}

/// The DAT state machine behind the channel: registration, one device
/// session, its photo capability and the capture button. Main actor only;
/// SDK callbacks hop here before touching state or emitting.
@MainActor
final class MetaDatController {
  typealias Emit = @MainActor ([String: Any]) -> Void

  /// A full-resolution HEIC is a few MB; anything this large is not a
  /// photo the pipeline should hold in memory.
  static let maxPhotoBytes = 50 * 1024 * 1024
  /// DAT fails a silent transfer after 30 s; a capture flag still set
  /// after this is cleared so the button never stays dead.
  static let captureTimeout: TimeInterval = 40
  /// How long a photo startup may take before it counts as failed
  /// (MetaDatPhotoStartup). Meta names no figure; a startup that works
  /// takes about a second on Mock Device Kit.
  static let photoStartupTimeout: TimeInterval = 10

  private let emit: Emit
  private(set) var configured = false
  private var wearablesTokens: [any AnyListenerToken] = []

  /// ONE selector for the controller's life, watched from configure on: a
  /// selector made at startSession has no active device yet, and DAT
  /// refuses the session (noEligibleDevice) until it picks one.
  private var selector: AutoDeviceSelector?
  private var selectorTask: Task<Void, Never>?
  private(set) var hasActiveDevice = false

  private var session: DeviceSession?
  private var sessionTokens: [any AnyListenerToken] = []
  private var lastSessionState: DeviceSessionState = .idle

  private var camera: Camera?
  private var photo: Photo?
  private var photoState: PhotoState = .stopped
  private var photoTokens: [any AnyListenerToken] = []
  private(set) var captureInFlight = false
  private var captureWatchdog: DispatchWorkItem?

  private(set) var photoStartup = MetaDatPhotoStartup()
  private var photoStartupWatchdog: DispatchWorkItem?
  /// [photoStartupTimeout], shortened by RunnerTests.
  var photoStartupTimeout = MetaDatController.photoStartupTimeout
  /// Cameras added over the controller's life (RunnerTests: a retry adds a
  /// fresh one).
  private(set) var camerasAdded = 0

  private var inputsAttached = false
  private var inputsTokens: [any AnyListenerToken] = []
  private var inputsTask: Task<Void, Never>?

  #if METADAT_MOCK
    private var mockGlasses: (any MockGlasses)?

    /// RunnerTests only. Mock Device Kit can fail a capture
    /// (simulateCaptureFailure) but never a photo STARTUP, so the next
    /// startups take these faults instead, in order. Each is fed through
    /// the same entry points the photo's listeners use, and the photo is
    /// never asked to start:
    /// - setupFailed: `.starting`, then sessionSetupFailed (DAT on iOS);
    /// - stoppedAfterStarting: `.starting`, then `.stopped`;
    /// - silent: nothing at all, so only the startup timeout ends it.
    enum PhotoStartupFault { case setupFailed, stoppedAfterStarting, silent }
    var photoStartupFaults: [PhotoStartupFault] = []
  #endif

  init(emit: @escaping Emit) {
    self.emit = emit
  }

  // MARK: - status and configuration

  func status() -> [String: Any] {
    var mock = false
    var mockAvailable = false
    #if METADAT_MOCK
      mock = mockGlasses != nil
      mockAvailable = true
    #endif
    // Wearables.shared must not be touched before configure().
    let registration = configured ? MetaDatWire.registration(Wearables.shared.registrationState) : "unknown"
    let devices = configured ? Wearables.shared.devices.count : 0
    return [
      "supported": true,
      "configured": configured,
      "registration": registration,
      "devices": devices,
      "activeDevice": hasActiveDevice,
      "session": MetaDatWire.session(lastSessionState),
      "camera": MetaDatWire.camera(photoState),
      "mock": mock,
      "mockAvailable": mockAvailable,
    ]
  }

  /// Wearables.configure() exactly once per process (a second call is
  /// `alreadyConfigured`, which counts as success), then the registration
  /// and device listeners.
  func configure() throws -> [String: Any] {
    if !configured {
      do {
        try Wearables.configure()
      } catch {
        // alreadyConfigured: another controller in this process
        // (RunnerTests) got there first, which is fine.
        // (`configure` throws only WearablesError: typed throws.)
        if error != .alreadyConfigured {
          throw MetaDatFailure("configure", String(describing: error))
        }
      }
      configured = true
      let w = Wearables.shared
      wearablesTokens = [
        w.addRegistrationStateListener { [weak self] state in
          let wire = MetaDatWire.registration(state)
          Task { @MainActor in self?.emit(["type": "registration", "state": wire]) }
        },
        w.addDevicesListener { [weak self] ids in
          let count = ids.count
          Task { @MainActor in self?.emit(["type": "devices", "count": count]) }
        },
      ]
      let selector = AutoDeviceSelector(wearables: w)
      self.selector = selector
      selectorTask = Task { @MainActor [weak self] in
        for await id in selector.activeDeviceStream() {
          guard let self else { return }
          let active = id != nil
          if active != self.hasActiveDevice {
            self.hasActiveDevice = active
            self.emit(["type": "activeDevice", "active": active])
          }
        }
      }
    }
    return status()
  }

  private func requireConfigured() throws {
    guard configured else {
      throw MetaDatFailure("not_configured", "Call configure first.")
    }
  }

  func register() async throws {
    try requireConfigured()
    do {
      try await Wearables.shared.startRegistration()
    } catch {
      throw MetaDatFailure("registration", String(describing: error))
    }
  }

  func unregister() async throws {
    try requireConfigured()
    do {
      try await Wearables.shared.startUnregistration()
    } catch {
      throw MetaDatFailure("unregistration", String(describing: error))
    }
  }

  /// The Meta AI app's callback (`bitewise-glasses://…?metaWearablesAction=…`),
  /// forwarded by Dart from the app's link stream. Only DAT callbacks get
  /// here: Dart filters on the scheme and the query item, as Meta's
  /// samples do.
  func handleUrl(_ url: URL) async throws -> Bool {
    try requireConfigured()
    do {
      return try await Wearables.shared.handleUrl(url)
    } catch {
      throw MetaDatFailure("callback", String(describing: error))
    }
  }

  func requestCameraPermission() async throws -> String {
    try requireConfigured()
    do {
      var status = try await Wearables.shared.checkPermissionStatus(.camera)
      if status != .granted {
        status = try await Wearables.shared.requestPermission(.camera)
      }
      return MetaDatWire.permission(status)
    } catch {
      throw MetaDatFailure("permission", String(describing: error))
    }
  }

  /// Meta AI's page that updates the toolkit's app on the glasses: the
  /// remedy for `session_update_glasses_app` (Meta's CameraAccess sample
  /// offers the same).
  func openGlassesAppUpdate() async throws {
    try requireConfigured()
    do {
      try await Wearables.shared.openDATGlassesAppUpdate()
    } catch {
      throw MetaDatFailure("navigation", String(describing: error))
    }
  }

  // MARK: - session

  /// One session at a time, on the glasses the selector picked.
  /// Capabilities are attached once the session reports `.started`.
  func startSession() throws {
    try requireConfigured()
    if session != nil { return }
    guard let selector, hasActiveDevice else {
      throw MetaDatFailure("no_device", "No glasses are connected.")
    }
    let s: DeviceSession
    do {
      s = try Wearables.shared.createSession(deviceSelector: selector)
    } catch {
      throw MetaDatFailure(MetaDatWire.sessionError(error), String(describing: error))
    }
    session = s
    lastSessionState = .idle
    sessionTokens = [
      s.statePublisher.listen { [weak self] state in
        Task { @MainActor in self?.sessionStateChanged(state, of: s) }
      },
      // An error is news, not a state: the state publisher says whether
      // the session stopped.
      s.errorPublisher.listen { [weak self] error in
        let code = MetaDatWire.sessionError(error)
        let message = String(describing: error)
        Task { @MainActor in self?.emitError(code, message) }
      },
    ]
    do {
      try s.start()
    } catch {
      let code = MetaDatWire.sessionError(error)
      if code == MetaDatWire.versionWarning {
        // Not blocking (Meta): the session goes on, and the warning is
        // passed on as news.
        emitError(code, String(describing: error))
        return
      }
      sessionTokens = []
      session = nil
      throw MetaDatFailure(code, String(describing: error))
    }
  }

  func stopSession() {
    guard let s = session else { return }
    detachCapabilities()
    sessionTokens = []
    session = nil
    s.stop()
    lastSessionState = .stopped
    emit(["type": "session", "state": "stopped"])
  }

  private func sessionStateChanged(_ state: DeviceSessionState, of s: DeviceSession) {
    guard s === session else { return }
    let previous = lastSessionState
    lastSessionState = state
    emit(["type": "session", "state": MetaDatWire.session(state)])
    switch state {
    case .started:
      // DAT 1.0 known issue: beta capabilities do not resume with the
      // session, so a resumed session gets fresh ones.
      if previous == .paused { detachCapabilities() }
      attachCapabilities(on: s)
    case .stopped:
      detachCapabilities()
      sessionTokens = []
      session = nil
    default:
      break
    }
  }

  /// Photo capability and capture button, each attached once.
  private func attachCapabilities(on s: DeviceSession) {
    attachCamera(on: s)
    attachInputs(on: s)
  }

  /// The photo capability: explicit start on iOS, listeners first (nothing
  /// replays), and the startup watched by [photoStartup] — a failed one is
  /// retried once on a fresh camera before Dart hears photo_setup_failed.
  private func attachCamera(on s: DeviceSession) {
    guard camera == nil else { return }
    do {
      guard let cam = try s.addCamera() else {
        cameraNotAdded("The session has not started.")
        return
      }
      camerasAdded += 1
      camera = cam
      let p = cam.photo
      photo = p
      photoTokens = [
        p.statePublisher.listen { [weak self] state in
          Task { @MainActor in self?.photoStateReceived(state, of: p) }
        },
        // Wearer-initiated shots (the glasses' own shutter) arrive here
        // too, not only the ones capture() asks for.
        p.photoDataPublisher.listen { [weak self] data in
          Task { @MainActor in self?.deliver(data) }
        },
        p.transferProgressPublisher.listen { [weak self] progress in
          let fraction = progress.fraction
          Task { @MainActor in self?.emit(["type": "progress", "fraction": fraction]) }
        },
        p.errorPublisher.listen { [weak self] error in
          Task { @MainActor in self?.photoErrorReceived(error, of: p) }
        },
      ]
      photoStartup.began()
      armPhotoStartupWatchdog(for: p)
      #if METADAT_MOCK
        if !photoStartupFaults.isEmpty {
          injectStartupFault(photoStartupFaults.removeFirst(), into: p)
          return
        }
      #endif
      p.start()
    } catch {
      cameraNotAdded(String(describing: error))
    }
  }

  /// addCamera gave nothing: a first attempt says so as `camera`; a retry
  /// that cannot even add its camera is the failed retry.
  private func cameraNotAdded(_ message: String) {
    let retrying = photoStartup.retries > 0
    photoStartup.reset()
    emitError(retrying ? "photo_setup_failed" : "camera", message)
  }

  /// The capture button (Inputs, capture-button source only, so no
  /// touchpad gesture is taken from the glasses).
  private func attachInputs(on s: DeviceSession) {
    guard !inputsAttached else { return }
    do {
      if let inputs = try s.addInputs(
        configuration: InputsConfiguration(sources: [.captureButton]))
      {
        inputsAttached = true
        inputsTokens = [
          inputs.errorPublisher.listen { [weak self] error in
            let message = String(describing: error)
            Task { @MainActor in self?.emitError("inputs", message) }
          }
        ]
        let events = inputs.events
        inputsTask = Task { @MainActor [weak self] in
          for await event in events {
            if case let .capture(press, _, _) = event {
              self?.emit(["type": "button", "press": MetaDatWire.press(press)])
            }
          }
        }
      }
    } catch {
      emitError("inputs", String(describing: error))
    }
  }

  private func detachCapabilities() {
    inputsTask?.cancel()
    inputsTask = nil
    inputsTokens = []
    if inputsAttached, let s = session {
      try? s.removeInputs()
    }
    inputsAttached = false
    photoStartup.reset()
    dropCamera()
  }

  /// Stops and forgets the camera. Its listeners go first, so a stopped
  /// camera's late news cannot touch the next one (the identity guards
  /// below catch what was already on its way).
  private func dropCamera() {
    cancelPhotoStartupWatchdog()
    photoTokens = []
    camera?.stop()
    camera = nil
    photo = nil
    clearCapture()
    if photoState != .stopped {
      photoState = .stopped
      emit(["type": "camera", "state": "stopped"])
    }
  }

  private func photoStateReceived(_ state: PhotoState, of p: Photo) {
    guard p === photo else { return }
    photoState = state
    if state != .started { clearCapture() }
    emit(["type": "camera", "state": MetaDatWire.camera(state)])
    let action = photoStartup.on(state)
    if state == .started { cancelPhotoStartupWatchdog() }
    if action != .nothing {
      photoStartupFailed(action, "The photo capability stopped while starting.")
    }
  }

  private func photoErrorReceived(_ error: PhotoError, of p: Photo) {
    guard p === photo else { return }
    let message = String(describing: error)
    if case .sessionSetupFailed = error {
      let action = photoStartup.setupFailed()
      if action != .nothing {
        photoStartupFailed(action, message)
        return
      }
    }
    clearCapture()
    emitError(MetaDatWire.photoError(error), message)
  }

  private func armPhotoStartupWatchdog(for p: Photo) {
    cancelPhotoStartupWatchdog()
    let watchdog = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { self?.photoStartupTimedOut(of: p) }
    }
    photoStartupWatchdog = watchdog
    DispatchQueue.main.asyncAfter(deadline: .now() + photoStartupTimeout, execute: watchdog)
  }

  private func cancelPhotoStartupWatchdog() {
    photoStartupWatchdog?.cancel()
    photoStartupWatchdog = nil
  }

  private func photoStartupTimedOut(of p: Photo) {
    guard p === photo else { return }
    let action = photoStartup.timedOut()
    if action != .nothing {
      photoStartupFailed(action, "The photo capability did not start in time.")
    }
  }

  /// A failed startup: the camera is stopped and dropped either way; a
  /// retry adds a fresh one on the same session (only a started session:
  /// a paused one re-attaches on resume), a failed retry tells Dart.
  private func photoStartupFailed(_ action: MetaDatPhotoStartup.Action, _ message: String) {
    dropCamera()
    switch action {
    case .retry:
      if let s = session, lastSessionState == .started {
        attachCamera(on: s)
      } else {
        photoStartup.reset()
      }
    case .fail:
      emitError("photo_setup_failed", message)
    case .nothing:
      break
    }
  }

  // MARK: - capture

  /// One capture in flight at most: results carry no request id.
  func capture(resolution: String?, quality: String?) -> Bool {
    guard let p = photo, photoState == .started, !captureInFlight else { return false }
    captureInFlight = true
    let watchdog = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.captureInFlight else { return }
        self.clearCapture()
        self.emitError("capture_timeout", "No photo arrived.")
      }
    }
    captureWatchdog = watchdog
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureTimeout, execute: watchdog)
    p.capturePhoto(
      resolution: MetaDatWire.resolution(resolution), quality: MetaDatWire.quality(quality))
    return true
  }

  private func clearCapture() {
    captureWatchdog?.cancel()
    captureWatchdog = nil
    captureInFlight = false
  }

  /// The image bytes exactly as the glasses produced them (JPEG or HEIC,
  /// EXIF intact: the Dart pipeline strips metadata before any upload).
  /// `metadata` is opaque and nullable, never parsed.
  private func deliver(_ data: PhotoCaptureData) {
    clearCapture()
    let bytes = data.imageData
    guard !bytes.isEmpty, bytes.count <= Self.maxPhotoBytes else {
      emitError("photo_size", "Unexpected photo size: \(bytes.count) bytes.")
      return
    }
    emit([
      "type": "photo",
      "bytes": FlutterStandardTypedData(bytes: bytes),
      "receivedAtMs": Int64((data.timestamp.timeIntervalSince1970 * 1000).rounded()),
    ])
  }

  private func emitError(_ code: String, _ message: String) {
    emit(["type": "error", "code": code, "message": message])
  }

  // MARK: - Mock Device Kit (Debug config only: METADAT_MOCK)

  #if METADAT_MOCK
    /// Simulated Ray-Ban Meta glasses: registered, camera permission
    /// granted, powered on, unfolded and worn; standalone captures return
    /// [photo] (or a drawn plate when nil). For the simulator and
    /// RunnerTests; never in a release build.
    func enableMock(photo: Data?) throws {
      try requireConfigured()
      let kit = MockDeviceKit.shared
      if !kit.isEnabled { kit.enable() }
      let glasses: any MockGlasses
      if let paired = mockGlasses {
        glasses = paired
      } else {
        do {
          glasses = try kit.pairGlasses(model: .rayBanMeta)
        } catch {
          throw MetaDatFailure("mock", String(describing: error))
        }
        mockGlasses = glasses
      }
      glasses.powerOn()
      glasses.unfold()
      glasses.don()
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("metadat-mock-capture.jpg")
      do {
        try (photo ?? MetaDatMockFixture.plateJpeg()).write(to: url, options: .atomic)
      } catch {
        throw MetaDatFailure("mock", String(describing: error))
      }
      glasses.services.cameraCapture.setCapturedPhoto(fileURL: url)
    }

    /// A press of the simulated glasses' capture button.
    func mockCapturePress(_ press: String) -> Bool {
      guard let glasses = mockGlasses else { return false }
      let type: MWDATMockDevice.CapturePressType
      switch press {
      case "hold": type = .hold
      case "doublePress": type = .doublePress
      default: type = .shortPress
      }
      glasses.services.input.capture(pressType: type)
      return true
    }

    /// [photoStartupFaults]: what DAT would report, delivered the way its
    /// listeners deliver it (a hop to the main actor), for a photo that
    /// was never asked to start.
    private func injectStartupFault(_ fault: PhotoStartupFault, into p: Photo) {
      switch fault {
      case .setupFailed:
        Task { @MainActor [weak self] in
          self?.photoStateReceived(.starting, of: p)
          self?.photoErrorReceived(.sessionSetupFailed(underlying: nil), of: p)
        }
      case .stoppedAfterStarting:
        Task { @MainActor [weak self] in
          self?.photoStateReceived(.starting, of: p)
          self?.photoStateReceived(.stopped, of: p)
        }
      case .silent:
        break
      }
    }

    /// Tears the mock down (RunnerTests' tearDown).
    func disableMock() async {
      let s = session
      stopSession()
      // Let DAT finish stopping before the glasses go, and retire this
      // controller's selector: RunnerTests pair glasses afresh for every
      // test, and a selector or session left over from the last one
      // intermittently kept the next controller from ever being given
      // an active device.
      if let s {
        for _ in 0..<50 where s.state != .stopped {
          try? await Task.sleep(nanoseconds: 100_000_000)
        }
      }
      selectorTask?.cancel()
      selectorTask = nil
      selector = nil
      hasActiveDevice = false
      if let glasses = mockGlasses {
        await MockDeviceKit.shared.unpairDevice(glasses)
      }
      mockGlasses = nil
      await MockDeviceKit.shared.disable()
    }
  #endif
}

#if METADAT_MOCK
  /// The mock's capture fixture: a plate on a table, drawn here so the
  /// simulator needs no bundled photo.
  enum MetaDatMockFixture {
    static func plateJpeg(width: CGFloat = 1024, height: CGFloat = 768) -> Data {
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      let renderer = UIGraphicsImageRenderer(
        size: CGSize(width: width, height: height), format: format)
      return renderer.jpegData(withCompressionQuality: 0.85) { ctx in
        UIColor(red: 0.55, green: 0.38, blue: 0.24, alpha: 1).setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let plate = CGRect(
          x: width * 0.2, y: height * 0.12, width: width * 0.6, height: height * 0.76)
        UIColor.white.setFill()
        ctx.cgContext.fillEllipse(in: plate)
        UIColor(red: 0.95, green: 0.75, blue: 0.2, alpha: 1).setFill()
        ctx.cgContext.fillEllipse(in: plate.insetBy(dx: plate.width * 0.22, dy: plate.height * 0.25))
        UIColor(red: 0.2, green: 0.6, blue: 0.25, alpha: 1).setFill()
        ctx.cgContext.fillEllipse(
          in: CGRect(x: plate.midX - 40, y: plate.minY + 40, width: 80, height: 60))
      }
    }
  }
#endif
