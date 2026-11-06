# Meta glasses session (DAT prototype)

Branch `feat/meta-dat` only. It is not merged into
`feat/glasses-restaurant-assist` or `main`, and it is off in every build
unless you turn it on with a build flag.

This branch connects Bitewise to Meta's **Wearables Device Access Toolkit**
(DAT, [github.com/facebook/meta-wearables-dat-ios](https://github.com/facebook/meta-wearables-dat-ios),
pinned to **1.0.1**). While a "glasses session" screen is open, every photo
the glasses take comes straight into the app. It goes through the same
photo pipeline as a photo you pick yourself, and the meal is written with
source `app_glasses`.

The approved design keeps DAT out of the main feature. The main path is
the Photos auto-import that the Meta AI app already does. This prototype
is stage **L4**: something to try if hardware testing (H1) shows that
auto-import is too slow or unreliable.

## Status (2026-10-23)

| What | State |
|---|---|
| Swift bridge `ios/Runner/MetaDatPlugin.swift`, channel `dev.calorietracker/metadat` | Done |
| DAT 1.0.1 Swift package on the Runner target (Core, Camera, Inputs, MockDevice) | Done, `exactVersion`, `Package.resolved` committed |
| iOS deployment target 17.2 (Runner and RunnerTests; the share extension stays at 15.0) | This branch only |
| Dart wrapper, shutter-button arbiter, pipeline adapter, session screen | Done, behind `BITEWISE_META_DAT` |
| Dart tests (`app/test/glasses/`, 76 tests: mocked channel, screen, real SQLite ledger, native wiring gate) | Pass; the full suite passes too |
| XCTest on Mock Device Kit (`ios/RunnerTests/MetaDatTests.swift`): configure → mock glasses → session → capture → photo bytes → capture-button event → stop; events reaching the real channel; the photo-startup retry (every failure kind, through a test-only fault seam); every `DeviceSessionError` mapped to its own code | Passes on the simulator |
| Simulator end to end with both flags on: + → Meta glasses session → Start → Take a photo, then the mock shutter button | Works. Both mock photos went through the real pipeline and the configured AI ("no food recognized" for the drawn plate) |
| Simulator Debug build and a Release device build (`generic/platform=iOS`) | Both build. Nothing was installed on a phone |
| Real glasses | **Not tested.** No hardware yet; see "Open questions" |
| Anything on Meta's developer site | **Not done.** These are owner steps, below |

## Limits

- **Experimental and unpublishable.** In DAT 1.0, standalone photo capture
  and Inputs (the capture button) are labelled experimental: "apps that
  use it cannot be published yet". Meta also says the App Store will
  currently reject any app built on DAT, because it uses the
  ExternalAccessory framework (MFi rules). To share it, use a Meta
  release channel and your own signed build, never TestFlight or the App
  Store.
- **iOS floor 17.2 on this branch.** The SDK's frameworks need it. Your
  only iOS device (iOS 27) is far above it, so in practice nothing is
  lost. `main` keeps 15.0.
- **The session must be active, and the screen must stay open.**
  Photos arrive only while a session runs and the Glasses session screen
  is open. Going back from the screen ends the session. Locking the phone
  or switching to another app does not end it at once: Bitewise keeps it
  for **15 minutes** in the background, then ends it itself. Whether DAT
  keeps the session running while the phone is locked is not documented
  (Meta's lifecycle guide lists folding, another experience, another
  app's session and a lost Meta AI link as what ends one); that is open
  question 4 below. Folding the glasses ends the session, and opening them
  does not restart it. DAT cannot launch Bitewise when you take a photo,
  so this is a "sit down and shoot your meal" tool. It does not replace
  automatic logging.
- **Bluetooth only, no Wi-Fi link.** DAT's Wi-Fi link needs the Hotspot
  Configuration capability, and a free Apple developer team cannot sign
  it. So this branch declares only the Bluetooth LE and Bluetooth Classic
  links (`bluetooth-central`, `bluetooth-peripheral`,
  `external-accessory`, `com.meta.ar.wearable`). There is no
  local-network prompt.
- **Photo size.** Captures default to DAT's `large` size (1080p class) at
  high quality. That is plenty for a food photo and much faster over
  Bluetooth than `full` (4032×3024). DAT fails a transfer after 30 s of
  silence. Bitewise clears a capture that has not arrived after 40 s.
- **Versions.** DAT 1.0.1 needs Meta AI app V292+ and glasses firmware
  V128+. Meta's known issue: reboot the glasses after the V128 update, or
  capture does not work.
- **App size.** The DAT frameworks add about 50 MB unpacked (Core alone
  is 35 MB). Swift Package Manager cannot link a product into one
  configuration only, so the Mock Device Kit framework (about 9 MB) is
  embedded in Release builds too. Its code is compiled only into Debug
  (`METADAT_MOCK`), and the Release binary references none of it.
- **Developer Mode allows one third-party app at a time.** Registering
  Bitewise unregisters any other Developer Mode app.

## Privacy

- DAT collects analytics and crash reports **by default**. Info.plist
  opts out of both (`MWDAT > Analytics > OptOut = true`,
  `MWDAT > CrashReporting > OptOut = true`). A test
  (`meta_dat_wiring_test.dart`) fails if either key goes missing.
- Glasses photos take the same path as a photo you pick. The pipeline
  makes the small upload JPEG with no EXIF or GPS and sends it to the AI
  service chosen in Settings. The original bytes are never saved; only
  the meal thumbnail is kept.
- No Meta identifier or token is committed. `MetaAppID` and
  `ClientToken` are the build settings `$(META_APP_ID)` and
  `$(META_CLIENT_TOKEN)`. They come from an **untracked**
  `app/ios/Flutter/MetaDat.xcconfig`, which is gitignored and optional.
  In Developer Mode both stay empty, and DAT then skips attestation.
- Meta's [Developer Terms](https://wearables.developer.meta.com/terms) and
  [Acceptable Use Policy](https://wearables.developer.meta.com/acceptable-use-policy)
  apply to anyone who uses the SDK. They are yours to read and accept.
  Nothing on this branch accepts them for you.

## How it works

```
glasses ──BT──> DAT (MWDATCore/Camera/Inputs) ──> MetaDatPlugin.swift (MetaDatController)
   │                                                   │  channel dev.calorietracker/metadat
   │                                                   ▼
   └ capture button ─> Inputs ─> "button" event ─> MetaDatChannel ─> ShutterArbiter
                                                       │ "photo" event (JPEG/HEIC bytes)
                                                       ▼
                         glassesIntakePhoto() ─> PhotoPipeline.enqueue  (source app_glasses,
                                                                         deliberate intake)
```

- **Native** (`ios/Runner/MetaDatPlugin.swift`): `MetaDatController` is
  the state machine: configure, registration, one device session, the
  photo capability and the capture button. `MetaDatWire` maps SDK states
  to the wire strings. The plugin is registered for the app's own engine
  only (`AppDelegate.registerForegroundOnlyPlugins`), never for
  workmanager's headless engine. Registering it does not touch the SDK:
  `Wearables.configure()` runs only when Dart calls `configure`.
  - **Mock Device Kit:** compiled only into the Debug configuration
    (Swift condition `METADAT_MOCK`).
  - **Device choice:** a long-lived `AutoDeviceSelector` picks the
    glasses. DAT refuses a session until it has picked one, and the
    controller reports that as `no_device`.
  - **Pause and resume:** after a resume, the capabilities are attached
    again, because of DAT's known issue that beta capabilities do not
    resume.
  - **Photo startup retry:** Meta's camera-capture guide calls startup
    "the most common failure point". `MetaDatPhotoStartup` watches each
    startup until `.started`, under a 10 s timeout. A fall back to
    `.stopped` after `.starting`, a `sessionSetupFailed` or the timeout
    stops that camera and adds a fresh one, once. Dart hears
    `photo_setup_failed` only when the retry fails too. The count resets
    when a startup works.
  - **Session errors:** each `DeviceSessionError` keeps its own wire code,
    because Meta's version guide says they are not equally recoverable:
    `session_update_glasses_app` (the screen offers **Update in Meta AI**,
    `openDATGlassesAppUpdate()`), `session_sdk_too_old` (only a newer
    Bitewise build helps), `session_version_warning` (`dwaOutOfStuRange`:
    the session goes on, and the screen says so once and stops nothing),
    `session_glasses_app_unavailable` (the toolkit's app on the glasses
    did not start; its install fails below 10% battery),
    `session_thermal`, `session_battery`, and `no_device`. Everything else
    is `session`.
- **Dart** (`app/lib/services/glasses/`):
  - `meta_dat_channel.dart`: typed methods, parsed events (a malformed
    payload is dropped), and the callback-link filter.
  - `shutter_arbiter.dart`: one press gives one photo (see "Open
    questions").
  - `glasses_intake.dart`: the only meeting point with the pipeline.
  - `meta_dat_flags.dart`: the two build flags.
- **Screen**: `app/lib/ui/screens/glasses_session_screen.dart`. It opens
  from the + sheet ("Meta glasses session"), but only with the flag on
  and only on an iPhone. Its strings live in `glasses_session_strings.dart`
  (en and zh), not in the ARB files, so this prototype does not collide
  with the lanes that are editing them.
- **Pipeline hook**: `IntakePhoto.source` is a getter: `app_photo` /
  `app_watch` as before, overridden to `app_glasses` by
  `GlassesIntakePhoto`. `MealSource.appGlasses` is the new wire value.
  The ledger treats it like any deliberate source: a stale `processing`
  row becomes `failed` and the user can retry it.
- **Dating**: a glasses-session meal is dated by the time the **phone**
  received the photo. That is seconds after the shutter, and it is
  validated like any capture time. It is not dated by the glasses' EXIF
  clock, whose time zone is unverified.

## Owner steps (on Meta's side; none of these were done for you)

For your own glasses with your own build, **Developer Mode is enough**. You
need no Meta account work, no app ID and no token:

1. Update the **Meta AI** app to V292 or later, and the glasses firmware
   to V128 or later (Meta AI → Devices → your glasses → gear → General →
   About → Version). After the V128 update, turn the glasses off and on
   again.
2. In Meta AI: **Settings → App Info**. Tap the app version **5 times**,
   turn on **Developer Mode** and confirm with **Enable**.
3. Install a build of this branch with the flag on (the orchestrator
   does the install; see the build commands below).
4. In Bitewise: **+ → Meta glasses session → Link Bitewise in Meta AI**.
   Meta AI opens. Approve Bitewise there, and Meta AI sends you back to
   Bitewise (link `bitewise-glasses://…`). Bitewise then appears in Meta
   AI under **App connections → Developer mode apps**.
5. **Start session**. The first time, Meta AI asks for the glasses-camera
   permission. Choose **Allow always**, or **Allow once** to be asked
   again next time.

Only to let **other people** use it, or to run without Developer Mode:

6. Sign in at [wearables.developer.meta.com](https://wearables.developer.meta.com/).
   If you are signed in at developers.meta.com (Horizon), sign out there
   first; Meta lists that as a known issue. Accept the Developer Terms
   and onboard an organization.
7. **New project** (name and description). Under **Configuration**, add
   the iOS app: bundle ID `dev.calorietracker.calorieTracker` and your
   Apple Team ID (Xcode → Signing & Capabilities).
8. **Permissions** tab: justify **camera** ("photos of meals the wearer
   chooses to log, analyzed to estimate calories"). Under **Product
   listing**, give the app name and an icon of at most 200×200 PNG or
   JPEG.
9. Copy the generated **Meta App ID** and **Client Token** into a new,
   untracked `app/ios/Flutter/MetaDat.xcconfig`:
   ```
   META_APP_ID = <app id>
   META_CLIENT_TOKEN = <client token>
   ```
   Never commit this file. Never paste the token into a chat or a
   terminal transcript.
10. Create a **version** and wait until its build shows **Ready** (10–30
    minutes). Then add it to a **release channel** and invite your
    testers.

On Apple's side there is nothing new. The bundle ID is already
registered through Xcode's automatic signing, and the Bluetooth Classic
link needs only Info.plist keys, with no new entitlement. Free-team builds
still expire after 7 days.

## How to try it

All commands run from `app/` with
`export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
The Dart flags reach an xcodebuild build as `DART_DEFINES`, a
comma-separated list of base64 `KEY=value` strings:

- `BITEWISE_META_DAT=true` → `QklURVdJU0VfTUVUQV9EQVQ9dHJ1ZQ==`
- `BITEWISE_META_DAT_MOCK=true` → `QklURVdJU0VfTUVUQV9EQVRfTU9DSz10cnVl`

**Simulator, no hardware (Mock Device Kit glasses):**

```
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Debug \
  -sdk iphonesimulator -destination 'id=<sim udid>' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO \
  'DART_DEFINES=QklURVdJU0VfTUVUQV9EQVQ9dHJ1ZQ==,QklURVdJU0VfTUVUQV9EQVRfTU9DSz10cnVl' \
  -derivedDataPath <dd> build
xcrun simctl install <sim udid> <dd>/Build/Products/Debug-iphonesimulator/Runner.app
```

Open the app and go to **+ → Meta glasses session**. The screen shows
**Simulated** glasses. Tap **Start session**, then **Take a photo now**
or **Press the mock shutter button**. The mock's photo is a drawn plate.
It goes through the real pipeline and gets a real verdict ("not food"
with a working AI key, or the usual "no API key" message without one).

**Native tests (Mock Device Kit):**

```
xcodebuild test -workspace ios/Runner.xcworkspace -scheme Runner -configuration Debug \
  -sdk iphonesimulator -destination 'id=<sim udid>' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO \
  -only-testing:RunnerTests
```

**Dart tests:** `flutter test test/glasses` (and the whole suite with
`flutter test`).

**Release build for a phone** (flag on, mock compiled out; build only,
the orchestrator installs):

```
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates \
  'DART_DEFINES=QklURVdJU0VfTUVUQV9EQVQ9dHJ1ZQ==' -derivedDataPath <dd> build
```

## Open questions for the hardware test (H1)

1. **The capture button while Bitewise listens.** Do the glasses still
   take their own photo when Bitewise listens to the button (DAT says
   such shots arrive on the same publisher), or does Inputs swallow the
   press? `ShutterArbiter` handles both cases. A short press only *arms*
   a request. If a transfer or photo starts within 3 s, it does nothing.
   Otherwise it asks once. A double press (DAT sends a short press first)
   or a hold cancels it. Record which case happens.
2. **Duplicates with auto-import.** Does a photo taken during a session
   *also* land in the Meta AI gallery and then in Photos? If so, the
   automatic watcher could log it a second time. Identical bytes are
   caught by the md5 ledger, re-encoded copies are not. The integration
   fix is to attach lane A's capture metadata
   (`device = meta_glasses`, `signal = dat_session`, `shutter_key`) to
   `GlassesIntakePhoto`, so the duplicate-shutter guard (G2b) sees both.
3. How long a `large` photo takes over Bluetooth Classic, and whether
   `full` ever finishes inside the 30 s silence window.
4. Whether the session survives the phone screen locking with Bitewise
   in front. Bitewise does not end it for 15 minutes in the background,
   so this measures DAT itself. Start a session, lock the phone, and take
   a photo after 1 minute and again after 5 minutes. Then unlock and
   write down which photos arrived and what the Session row says. A
   community plugin reports 8–15 s on iOS 27.
5. The EXIF Make/Model of a DAT capture. It feeds lane A's
   glasses-detection table.
6. Any session error the screen shows. Each `DeviceSessionError` now has
   its own wording, and the update prompt has an **Update in Meta AI**
   button. Write down the exact text.

## Files

- `app/ios/Runner/MetaDatPlugin.swift`, `app/ios/RunnerTests/MetaDatTests.swift`
- `app/ios/Runner/AppDelegate.swift`: `registerForegroundOnlyPlugins`
- `app/ios/Runner/Info.plist`: `MWDAT`, URL scheme `bitewise-glasses`,
  Bluetooth keys and modes; `en.lproj`/`zh-Hans.lproj` `InfoPlist.strings`
- `app/ios/Runner.xcodeproj/project.pbxproj`: package, products, 17.2,
  `METADAT_MOCK` (Debug only);
  `app/ios/Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- `app/ios/Flutter/{Debug,Release}.xcconfig`: `#include? "MetaDat.xcconfig"`;
  `app/ios/.gitignore`
- `app/lib/services/glasses/`, `app/lib/ui/screens/glasses_session_*.dart`,
  `app/lib/ui/screens/add_flow.dart` (the entry)
- `app/lib/core/contracts.dart` (`MealSource.appGlasses`,
  `IntakePhoto.source`), `app/lib/ui/photo_pipeline.dart` (uses it)
- `app/test/glasses/`
