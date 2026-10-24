#!/usr/bin/env bash
# Real end-to-end iOS simulator run: boots the sim, resets app state,
# pre-grants photo permission, injects the test food photos, then drives
# app/integration_test/e2e_test.dart against LIVE Gemini.
#
# Usage: scripts/run_e2e_ios.sh <env-file>
#   <env-file> is a --dart-define-from-file .env with E2E_GEMINI_KEY=...
#   It lives OUTSIDE the repo; no key material is stored or printed here.
#   The two test photos (pizza.jpg, burger.jpg) are expected next to the
#   env file, or in $E2E_PHOTOS_DIR if set.
#
# Usage: scripts/run_e2e_ios.sh --scenario late_import_native
#   No key, no network (design G1a, 2026-10-23). Proves the photo library's
#   change history (ios/Runner/PhotoChangesPlugin.swift) sees a photo
#   another app imports late: the XCTest
#   RunnerTests/LateImportNativeScenarioTests takes a change token, then
#   this script adds, with `simctl addmedia`, a HEIC whose EXIF capture
#   time is two days old. insertedImagesSince must report it and the
#   watcher's createDate > cutoff query must not. It adds that one
#   synthetic photo to the simulator's library: point $E2E_SIM_UDID at a
#   scratch simulator. $E2E_DERIVED_DATA reuses a build (xcodebuild
#   -derivedDataPath); by default it builds into a temporary directory.
set -euo pipefail

BUNDLE_ID="dev.calorietracker.calorieTracker"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Simulator: $E2E_SIM_UDID if set, else a booted iPhone, else the first
# available iPhone. The old hardcoded default (ct-test) vanished with an
# Xcode update and silently broke every run (2026-09-28).
pick_simulator() {
  if [[ -n "${E2E_SIM_UDID:-}" ]]; then
    echo "$E2E_SIM_UDID"
    return
  fi
  xcrun simctl list devices available -j | python3 -c '
import json, sys
d = json.load(sys.stdin)["devices"]
c = [x for r, l in d.items() if "iOS" in r for x in l
     if x.get("isAvailable") and x["name"].startswith("iPhone")]
b = [x for x in c if x["state"] == "Booted"]
pick = (b or c)
sys.exit("no available iPhone simulator; set E2E_SIM_UDID") if not pick else None
print(pick[0]["udid"])'
}

boot_simulator() {
  echo "==> Booting simulator $1"
  xcrun simctl boot "$1" 2>/dev/null || true # tolerate already-booted
  xcrun simctl bootstatus "$1" -b
}

# The TCC grant is wiped when `flutter test` (re)installs the app, a
# `simctl privacy` call while the app runs KILLS it, and any concurrent
# simctl call in the install->launch window can wedge the launch. So the
# re-grant after install must avoid CoreSimulator entirely: poll the
# filesystem for the fresh app container, then write the TCC rows straight
# into the simulator's TCC.db with sqlite3 (row shape identical to what
# `simctl privacy grant` produces on this runtime). Runs in the background;
# prints its PID.
start_tcc_granter() {
  local udid="$1"
  local tcc_db="$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/Library/TCC/TCC.db"
  (
    # Wait for the app PROCESS (install-time TCC reset is already done by
    # then), detected via the process table only — no CoreSimulator calls.
    for _ in $(seq 1 6000); do # up to ~10 min of build time
      if pgrep -f "$udid.*Runner.app/Runner" >/dev/null 2>&1; then
        # Keep re-asserting the rows for a while: the first in-app photo
        # permission request comes ~10s after launch and must find them.
        # NOTE: this iOS 26 runtime requires auth_version=2 for
        # kTCCServicePhotos (tccd ignores v1 rows for Photos — the reason a
        # plain `simctl privacy grant photos`, which writes v1, never sticks),
        # while kTCCServiceMediaLibrary still uses v1.
        for _ in $(seq 1 200); do
          sqlite3 "$tcc_db" "INSERT OR REPLACE INTO access
            (service, client, client_type, auth_value, auth_reason,
             auth_version, indirect_object_identifier, flags)
            VALUES ('kTCCServicePhotos', '$BUNDLE_ID', 0, 2, 4, 2, 'UNUSED', 0);
            INSERT OR REPLACE INTO access
            (service, client, client_type, auth_value, auth_reason,
             auth_version, indirect_object_identifier, flags)
            VALUES ('kTCCServiceMediaLibrary', '$BUNDLE_ID', 0, 2, 4, 1,
                    'UNUSED', 0);" 2>/dev/null || true
          sleep 0.2
        done
        echo "==> (granter) photo permission TCC rows asserted post-launch"
        exit 0
      fi
      sleep 0.1
    done
  ) >&2 &
  echo $!
}

# --scenario late_import_native (see the usage above).
run_late_import_native() {
  local udid work name exif_date exif_offset dd log granter adder status
  udid="$(pick_simulator)"
  boot_simulator "$udid"
  work="$(mktemp -d "${TMPDIR:-/tmp}/bitewise_late_import.XXXXXX")"

  # A glasses-style name, unique per run so the test can find this photo
  # (and only this one) among the inserts.
  name="photo-$(date +%s)$(printf '%06d' $((RANDOM % 1000000)))_singular_display_fullPicture.HEIC"
  exif_date="$(date -v-2d '+%Y:%m:%d %H:%M:%S')"
  exif_offset="$(date -v-2d '+%z')"
  exif_offset="${exif_offset:0:3}:${exif_offset:3:2}"
  echo "==> Making $name (EXIF DateTimeOriginal $exif_date $exif_offset)"
  cat >"$work/make_heic.swift" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
// make_heic.swift <out.HEIC> <EXIF DateTimeOriginal> <EXIF OffsetTimeOriginal>
let args = CommandLine.arguments
let ctx = CGContext(
  data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0,
  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(red: 0.85, green: 0.55, blue: 0.2, alpha: 1)
ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
let dest = CGImageDestinationCreateWithURL(
  URL(fileURLWithPath: args[1]) as CFURL, UTType.heic.identifier as CFString, 1, nil)!
let props: [CFString: Any] = [
  kCGImagePropertyExifDictionary: [
    kCGImagePropertyExifDateTimeOriginal: args[2],
    kCGImagePropertyExifDateTimeDigitized: args[2],
    kCGImagePropertyExifOffsetTimeOriginal: args[3],
  ],
  kCGImagePropertyTIFFDictionary: [
    kCGImagePropertyTIFFMake: "Meta AI", kCGImagePropertyTIFFModel: "Ray-Ban Meta Smart Glasses",
  ],
]
CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
exit(CGImageDestinationFinalize(dest) ? 0 : 1)
SWIFT
  xcrun swift "$work/make_heic.swift" "$work/$name" "$exif_date" "$exif_offset"

  dd="${E2E_DERIVED_DATA:-$work/DerivedData}"
  local xcode_flags=(
    -workspace Runner.xcworkspace -scheme Runner
    -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$dd"
    # Xcode 27: `flutter build ios --simulator` fails in lipo; arm64 only.
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=-
    CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO
  )
  echo "==> Building the app and RunnerTests (derived data: $dd)"
  (cd "$REPO_ROOT/app/ios" && xcodebuild build-for-testing "${xcode_flags[@]}" -quiet)

  granter="$(start_tcc_granter "$udid")"
  # Adds the photo once the test has its token: the test drops a marker in
  # its own tmp directory, found through the filesystem (no simctl call in
  # the launch window).
  (
    local apps="$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/Containers/Data/Application"
    for _ in $(seq 1 1800); do # up to ~7 min
      if [[ -n "$(find "$apps" -maxdepth 3 -name "bitewise_late_import_ready_$name" 2>/dev/null | head -1)" ]]; then
        xcrun simctl addmedia "$udid" "$work/$name"
        echo "==> (adder) added $name"
        exit 0
      fi
      sleep 0.25
    done
    echo "==> (adder) the test never asked for the photo" >&2
  ) &
  adder=$!
  # Expanded now: the function's locals are gone by the time EXIT fires.
  trap "kill $granter $adder 2>/dev/null || true" EXIT

  echo "==> Running RunnerTests/LateImportNativeScenarioTests"
  log="$work/xctest.log"
  status=0
  # xcodebuild hands TEST_RUNNER_<name> to the test process as <name>. No
  # clones (the photo goes into THIS simulator's library), and no failure
  # diagnostics: collecting a sysdiagnose held xcodebuild ~10 silent minutes.
  (cd "$REPO_ROOT/app/ios" &&
    TEST_RUNNER_BITEWISE_SCENARIO=late_import_native \
    TEST_RUNNER_BITEWISE_SCENARIO_FILE="$name" \
    xcodebuild test-without-building "${xcode_flags[@]}" \
      -only-testing:RunnerTests/LateImportNativeScenarioTests \
      -parallel-testing-enabled NO -collect-test-diagnostics never) \
    >"$log" 2>&1 || status=$?
  grep -E "^Test [Cc]ase|error:|late_import_native:|TEST (SUCCEEDED|FAILED)" "$log" || true
  # A skipped test exits 0 too: only an explicit pass counts.
  if [[ $status -ne 0 ]] ||
    ! grep -qE "testInsertedImagesSinceSeesALateImportTheCreateDateQueryMisses(\]|\(\))' passed" "$log"; then
    echo "late_import_native FAILED (log: $log)" >&2
    return 1
  fi
  echo "==> late_import_native passed"
  rm -rf "$work"
}

if [[ "${1:-}" == "--scenario" ]]; then
  case "${2:-}" in
    late_import_native) run_late_import_native; exit $? ;;
    *) echo "unknown scenario: ${2:-} (known: late_import_native)" >&2; exit 2 ;;
  esac
fi

ENV_FILE="${1:?usage: run_e2e_ios.sh <env-file with E2E_GEMINI_KEY=...> | --scenario late_import_native}"
ENV_FILE="$(cd "$(dirname "$ENV_FILE")" && pwd)/$(basename "$ENV_FILE")"
[[ -f "$ENV_FILE" ]] || { echo "env file not found: $ENV_FILE" >&2; exit 1; }

UDID="$(pick_simulator)"
PHOTOS_DIR="${E2E_PHOTOS_DIR:-$(dirname "$ENV_FILE")}"

for f in "$PHOTOS_DIR/pizza.jpg" "$PHOTOS_DIR/burger.jpg"; do
  [[ -f "$f" ]] || { echo "test photo not found: $f" >&2; exit 1; }
done

boot_simulator "$UDID"

echo "==> Resetting app state (uninstall $BUNDLE_ID + keychain reset)"
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
# flutter_secure_storage lives in the simulator keychain and SURVIVES app
# uninstall — reset it so the onboarding (no-key) path is really exercised.
xcrun simctl keychain "$UDID" reset 2>/dev/null || true

echo "==> Pre-granting photo permissions (no dialog during the test)"
xcrun simctl privacy "$UDID" grant photos "$BUNDLE_ID"
xcrun simctl privacy "$UDID" grant media-library "$BUNDLE_ID" 2>/dev/null || true

# The post-install re-grant (start_tcc_granter, above).
GRANTER_PID="$(start_tcc_granter "$UDID")"
trap 'kill "$GRANTER_PID" 2>/dev/null || true' EXIT

echo "==> Injecting test food photos into the simulator gallery"
xcrun simctl addmedia "$UDID" "$PHOTOS_DIR/pizza.jpg" "$PHOTOS_DIR/burger.jpg"

echo "==> Running the integration test (LIVE Gemini)"
(cd "$REPO_ROOT/app" && flutter test integration_test/e2e_test.dart \
  -d "$UDID" \
  --dart-define-from-file="$ENV_FILE")
