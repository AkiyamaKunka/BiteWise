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
#
# Usage: scripts/run_e2e_ios.sh --scenario late_import_app
#   No key, no network beyond a local fake server (design G1b,
#   2026-10-24). The app's own paths for photos imported late with an old
#   capture time: (1) a headless background run (the engine BGAppRefresh
#   starts) logs one through the late-import pass while its createDate
#   scan lists nothing, and the watermark does not move; (2) with the app
#   open, one saved with an old date is logged by the live watcher's pass.
#   Each must give exactly one meal, dated at capture. A Debug build (the
#   VM service, through `flutter attach`), a fresh install, photo access
#   via TCC; setup and triggers go through VM service evaluation. A fresh
#   simulator asks once for notifications: the background run's meal card
#   waits on that answer AFTER the meal is saved, which the checks allow
#   for. $E2E_SIM_UDID is REQUIRED and that simulator is ERASED first (its
#   photo library must start empty); also $E2E_DERIVED_DATA and
#   $E2E_FAKE_SERVER_PORT (default 18765).
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

# Writes <dir>/make_heic.swift: a 2016x1512 HEIC of a drawn plate of food
# whose EXIF capture time is the one given and whose TIFF Make/Model say
# Meta glasses; the optional red component colours a corner patch, which
# makes each photo's bytes (and so its hash) its own. Over 2 MP, so the
# glasses preview guard (glasses.dart glassesPreviewMaxPixels) does not
# hold it for a full-size copy. A plate, so the on-device food check
# (design G3) lets it through either way: a classifier that sees scores it
# as food (plate 0.34 on a Mac's), a blind one (the iOS 26.2 simulator's,
# ImageIOBlindCheck) answers unsupported.
write_heic_maker() {
  cat >"$1/make_heic.swift" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
// make_heic.swift <out.HEIC> <EXIF DateTimeOriginal> <EXIF OffsetTimeOriginal> [red 0..1]
let args = CommandLine.arguments
let width = 2016, height = 1512
let w = CGFloat(width), h = CGFloat(height)
let ctx = CGContext(
  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func fill(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
  ctx.setFillColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}
fill(236, 228, 216) // the table
ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
let plate = CGRect(x: w * 0.21, y: h * 0.17, width: w * 0.58, height: h * 0.66)
fill(200, 200, 200) // the rim's edge
ctx.fillEllipse(in: plate)
fill(249, 249, 248)
ctx.fillEllipse(in: plate.insetBy(dx: 8, dy: 8))
ctx.setStrokeColor(red: 0.88, green: 0.88, blue: 0.88, alpha: 1)
ctx.setLineWidth(5)
ctx.strokeEllipse(in: plate.insetBy(dx: w * 0.065, dy: h * 0.087))
let colours: [(CGFloat, CGFloat, CGFloat)] = [
  (228, 200, 92), (216, 120, 60), (90, 145, 60), (160, 90, 40),
]
var seed: UInt64 = 20_261_024
func next() -> CGFloat {
  seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
  return CGFloat(seed >> 33) / CGFloat(UInt64(1) << 31)
}
for i in 0..<48 {
  let (r, g, b) = colours[i % colours.count]
  fill(r, g, b)
  let radius = (14 + next() * 26) * w / 1200
  let x = w * (0.34 + next() * 0.32), y = h * (0.36 + next() * 0.30)
  ctx.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
}
// A corner patch in the given red: each photo's bytes (and hash) its own.
ctx.setFillColor(
  red: args.count > 4 ? CGFloat(Double(args[4]) ?? 0.85) : 0.85, green: 0.55, blue: 0.2, alpha: 1)
ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
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
  write_heic_maker "$work"
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

# --scenario late_import_app (see the usage above). Helpers first; they
# share the scenario's state through these globals.
LA_UDID="" LA_WORK="" LA_WS="" LA_ATTACH_PID="" LA_ATTACHES=0 LA_CONSOLE_PID=""

la_fail() {
  echo "late_import_app FAILED: $* (work: $LA_WORK)" >&2
  exit 1
}

# The app's data container (Documents, Library, tmp).
la_container() { xcrun simctl get_app_container "$LA_UDID" "$BUNDLE_ID" data; }

# The app's pid, or '' when it is not running.
la_pid() {
  xcrun simctl spawn "$LA_UDID" launchctl list 2>/dev/null |
    awk -v app="UIKitApplication:$BUNDLE_ID" 'index($3, app) == 1 && $1 ~ /^[0-9]+$/ {print $1}'
}

# (Re)launches the app cold (so its launch catch-up runs before any step),
# then attaches the flutter tool to its Dart VM service: `evaluate` needs
# the tool's expression compiler, and a killed process takes the old
# attachment with it. With a console (--console-pty), the launch form under
# which the connection held best while probing this; even so it does not
# reliably survive the app leaving the foreground, so no step needs that.
la_launch() {
  local old pid url log
  old="$(la_pid)"
  LA_ATTACHES=$((LA_ATTACHES + 1))
  [[ -n "$LA_CONSOLE_PID" ]] && kill "$LA_CONSOLE_PID" 2>/dev/null || true
  xcrun simctl launch --console-pty --terminate-running-process "$LA_UDID" \
    "$BUNDLE_ID" >"$LA_WORK/console.$LA_ATTACHES.log" 2>&1 &
  LA_CONSOLE_PID=$!
  # Generous waits throughout: a simulator another job is testing on can
  # take minutes to answer.
  pid=""
  for _ in $(seq 1 180); do
    pid="$(la_pid)"
    [[ -n "$pid" && "$pid" != "$old" ]] && break
    pid=""
    sleep 1
  done
  [[ -n "$pid" ]] || la_fail "the app did not launch"
  url=""
  for _ in $(seq 1 120); do
    url="$(xcrun simctl spawn "$LA_UDID" log show --last 5m --style compact \
      --predicate "processID == $pid" 2>/dev/null |
      grep -o 'Dart VM service is listening on http://[^ ]*' | tail -1 |
      sed 's/.* on //')" || true
    [[ -n "$url" ]] && break
    sleep 1
  done
  [[ -n "$url" ]] || la_fail "no Dart VM service from pid $pid (a Debug build is needed)"
  la_detach
  log="$LA_WORK/attach.$LA_ATTACHES.log"
  (cd "$REPO_ROOT/app" &&
    exec flutter attach -d "$LA_UDID" --debug-url "$url" </dev/null >"$log" 2>&1) &
  LA_ATTACH_PID=$!
  LA_WS=""
  for _ in $(seq 1 180); do
    LA_WS="$(grep -o 'is available at: http://[^ ]*' "$log" | head -1 |
      sed 's/is available at: http/ws/')" || true
    [[ -n "$LA_WS" ]] && break
    sleep 1
  done
  [[ -n "$LA_WS" ]] || la_fail "flutter attach did not connect (log: $log)"
  LA_WS="${LA_WS}ws"
  echo "==> App pid $pid, VM service attached"
}

# Ends the flutter tool's attachment (and its DDS, which would refuse the
# next one).
la_detach() {
  [[ -n "$LA_ATTACH_PID" ]] && kill "$LA_ATTACH_PID" 2>/dev/null || true
  pkill -f "flutter_tools.snapshot attach -d $LA_UDID" 2>/dev/null || true
  LA_ATTACH_PID=""
  sleep 1
}

# la_eval <library uri> <expression>...: evaluated in the app's main
# isolate, in that library's scope; prints "<expression> => <value>".
la_eval() {
  (cd "$LA_WORK" && dart run \
    --packages="$REPO_ROOT/app/.dart_tool/package_config.json" \
    vm_eval.dart "$LA_WS" "$@")
}

# la_sql <query>: against a copy of the app's database.
la_sql() {
  rm -rf "$LA_WORK/db" && mkdir -p "$LA_WORK/db"
  cp "$(la_container)"/Documents/calorie_tracker.db* "$LA_WORK/db/" 2>/dev/null || true
  sqlite3 "$LA_WORK/db/calorie_tracker.db" "$1" 2>/dev/null || true
}

# la_pref <key>: a shared_preferences value ('' when unset), as the app
# holds it now: through cfprefsd, since the plist file on disk can lag the
# app's writes by many seconds.
la_pref() {
  xcrun simctl spawn "$LA_UDID" defaults export \
    "$(la_container)/Library/Preferences/$BUNDLE_ID" - 2>/dev/null |
    plutil -convert json -o - - 2>/dev/null |
    python3 -c 'import json, sys; print(json.load(sys.stdin).get("flutter." + sys.argv[1], ""))' "$1" \
      2>/dev/null || true
}

la_analyses() { grep -c 'analyze_photo' "$LA_WORK/server.log" || true; }

# la_addmedia <file>: simctl addmedia, given at most 3 minutes (the first
# import into a new simulator's library can take a while).
la_addmedia() {
  xcrun simctl addmedia "$LA_UDID" "$1" &
  local p=$!
  for _ in $(seq 1 180); do
    if ! kill -0 "$p" 2>/dev/null; then
      wait "$p" || la_fail "addmedia failed"
      return 0
    fi
    sleep 1
  done
  kill "$p" 2>/dev/null || true
  la_fail "addmedia still running after 3 minutes"
}

# la_wait_meals <n> <date> <what>: waits up to 90 s for the n-th meal,
# then wants exactly n meals, the newest dated <date>, and n analyses.
la_wait_meals() {
  local count=0
  for _ in $(seq 1 90); do
    count="$(la_sql 'select count(*) from meals')"
    [[ "$count" -ge "$1" ]] && break
    sleep 1
  done
  [[ "$count" == "$1" ]] || la_fail "$3: $count meals, not $1"
  [[ "$(la_sql 'select date from meals order by id desc limit 1')" == "$2" ]] ||
    la_fail "$3: the new meal is not dated $2 (its capture day)"
  [[ "$(la_analyses)" == "$1" ]] || la_fail "$3: $(la_analyses) analyses, not $1"
}

run_late_import_app() {
  local dd app port b_name b_date e_name e_date cont mark runs
  # Erased first: photos earlier runs added would otherwise be in the
  # lookback window, and in the counts below.
  [[ -n "${E2E_SIM_UDID:-}" ]] || {
    echo "late_import_app erases its simulator: set E2E_SIM_UDID to a scratch one" >&2
    exit 2
  }
  LA_UDID="$E2E_SIM_UDID"
  echo "==> Erasing simulator $LA_UDID"
  xcrun simctl shutdown "$LA_UDID" 2>/dev/null || true
  xcrun simctl erase "$LA_UDID"
  boot_simulator "$LA_UDID"
  LA_WORK="$(mktemp -d "${TMPDIR:-/tmp}/bitewise_late_app.XXXXXX")"
  port="${E2E_FAKE_SERVER_PORT:-18765}"

  # Two glasses-style photos taken ~2 days ago; the lookback is set to 7.
  write_heic_maker "$LA_WORK"
  b_name="photo-$(date +%s)000002_singular_display_fullPicture.HEIC"
  e_name="photo-$(date +%s)000005_singular_display_fullPicture.HEIC"
  b_date="$(date -v-49H '+%Y-%m-%d')"
  e_date="$(date -v-53H '+%Y-%m-%d')"
  local off
  off="$(date -v-49H '+%z')"
  xcrun swift "$LA_WORK/make_heic.swift" "$LA_WORK/$b_name" \
    "$(date -v-49H '+%Y:%m:%d %H:%M:%S')" "${off:0:3}:${off:3:2}" 0.35
  off="$(date -v-53H '+%z')"
  xcrun swift "$LA_WORK/make_heic.swift" "$LA_WORK/$e_name" \
    "$(date -v-53H '+%Y:%m:%d %H:%M:%S')" "${off:0:3}:${off:3:2}" 0.95

  # The VM service client: `dart run` with the app's package config, which
  # already resolves package:vm_service.
  cat >"$LA_WORK/vm_eval.dart" <<'DART'
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> args) async {
  final service = await vmServiceConnectUri(args[0]);
  try {
    final vm = await service.getVM();
    final ref = vm.isolates!.firstWhere((i) => i.name == 'main',
        orElse: () => vm.isolates!.first);
    final isolate = await service.getIsolate(ref.id!);
    final lib = isolate.libraries!.firstWhere((l) => l.uri == args[1]);
    for (final expression in args.skip(2)) {
      final r = await service.evaluate(ref.id!, lib.id!, expression);
      final value = r is InstanceRef
          ? (r.valueAsString ?? r.classRef?.name)
          : (r is ErrorRef ? 'ERROR ${r.message}' : '$r');
      print('${expression.split('(').first} => $value');
    }
  } finally {
    await service.dispose();
  }
}
DART

  # A stand-in for the owner's server: every photo is a meal, named by
  # its size. No key material: the app is given 'e2e-key'.
  cat >"$LA_WORK/fake_server.py" <<'PY'
import base64, json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
LOG = sys.argv[2]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def _reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        self._reply(200, {'ok': True})
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('content-length') or 0))
        with open(LOG, 'a') as f:
            f.write(time.strftime('%H:%M:%S ') + self.path + '\n')
        if self.path != '/api/analyze_photo':
            return self._reply(404, {'ok': False})
        body = json.loads(raw or b'{}')
        size = len(base64.b64decode(body.get('image_b64', '')))
        self._reply(200, {'ok': True, 'analyzed_by': body.get('backend', 'claude'),
            'analysis': {'is_food': True, 'meal_description': f'E2E plate {size}',
                'food_items': [{'name': 'Pancakes', 'estimated_calories': 420,
                    'protein_g': 9, 'carbs_g': 60, 'fat_g': 15}],
                'total_calories': 420, 'total_protein_g': 9,
                'total_carbs_g': 60, 'total_fat_g': 15}})
ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PY
  : >"$LA_WORK/server.log"
  python3 -I "$LA_WORK/fake_server.py" "$port" "$LA_WORK/server.log" &
  local server_pid=$!
  trap "kill $server_pid \$LA_CONSOLE_PID 2>/dev/null; la_detach" EXIT

  dd="${E2E_DERIVED_DATA:-$LA_WORK/DerivedData}"
  echo "==> Building the Debug app (derived data: $dd)"
  (cd "$REPO_ROOT/app/ios" && xcodebuild build -workspace Runner.xcworkspace \
    -scheme Runner -configuration Debug \
    -destination "platform=iOS Simulator,id=$LA_UDID" -derivedDataPath "$dd" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO -quiet)
  app="$dd/Build/Products/Debug-iphonesimulator/Runner.app"

  echo "==> Fresh install, photo access granted"
  xcrun simctl terminate "$LA_UDID" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl uninstall "$LA_UDID" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl install "$LA_UDID" "$app"
  # The rows `simctl privacy grant` cannot write on this runtime (see
  # start_tcc_granter), written once: no `flutter test` reinstall follows.
  sqlite3 "$HOME/Library/Developer/CoreSimulator/Devices/$LA_UDID/data/Library/TCC/TCC.db" \
    "INSERT OR REPLACE INTO access (service, client, client_type, auth_value,
       auth_reason, auth_version, indirect_object_identifier, flags)
     VALUES ('kTCCServicePhotos', '$BUNDLE_ID', 0, 2, 4, 2, 'UNUSED', 0);
     INSERT OR REPLACE INTO access (service, client, client_type, auth_value,
       auth_reason, auth_version, indirect_object_identifier, flags)
     VALUES ('kTCCServiceMediaLibrary', '$BUNDLE_ID', 0, 2, 4, 1, 'UNUSED', 0);"

  echo "==> Setting up: the fake server, a 7-day lookback, the watcher on"
  la_launch
  la_eval package:calorie_tracker/ui/di.dart \
    "AppServices.instance.settings.setServerBaseUrl('http://127.0.0.1:$port')" \
    "AppServices.instance.settings.setServerBackend('claude')" \
    "AppServices.instance.settings.setServerApiKey('e2e-key')" \
    "AppServices.instance.settings.setProvider(AiProvider.server)" \
    "AppServices.instance.settings.setLookbackDays(7)" \
    "AppServices.instance.settings.setWatcherDisclosureSeen(true)" \
    "AppServices.instance.settings.setWatcherEnabled(true)"
  sleep 2
  la_launch # a cold launch with the watcher on: the cursor starts here
  cont="$(la_container)"
  for _ in $(seq 1 30); do
    [[ -f "$cont/Library/Application Support/bitewise_local/photo_change_cursor.json" ]] && break
    sleep 1
  done
  [[ -f "$cont/Library/Application Support/bitewise_local/photo_change_cursor.json" ]] ||
    la_fail "the late-import cursor was never started"

  echo "==> 1. Background run: $b_name"
  # A recent background watermark, as on a phone whose runs keep up: the
  # run's createDate scan then lists only the last hour.
  la_eval package:calorie_tracker/ui/background_glue.dart \
    "SharedPreferences.getInstance().then((p) => p.setString(backgroundWatermarkPrefsKey, DateTime.now().toUtc().toIso8601String()))"
  sleep 1
  mark="$(la_pref background.last_scan_iso)"
  [[ -n "$mark" ]] || la_fail "no background watermark was set"
  # `simctl addmedia` DOES reach the app's library observer on current
  # runtimes (review 2026-10-25), so the foreground live watcher would log
  # the photo first and the background run would find it already tracked.
  # Stop it: the app stays idle, as in the background, and no launch or
  # resume runs a catch-up until scenario 2 relaunches it. (Leaving the app
  # would be closer to life, but the VM service connection does not
  # reliably survive that.)
  la_eval package:calorie_tracker/ui/di.dart \
    "AppServices.instance.ui.photoIntake?.stop()"
  la_addmedia "$LA_WORK/$b_name"
  # The headless engine, as a BGAppRefresh launch starts it, right away.
  # The run's record below says which engine logged the photo.
  la_eval package:calorie_tracker/services/photo/background.dart \
    "Workmanager().registerOneOffTask(photoBackfillUniqueName, photoBackfillTaskName)"
  la_wait_meals 1 "$b_date" "background run"
  [[ "$(la_pref background.last_scan_iso)" == "$mark" ]] ||
    la_fail "background run: a late photo moved the watermark"
  # The run's own record: the headless engine saved the photo though its
  # createDate scan listed nothing (written as the photo lands, so give it
  # a moment).
  local ok=""
  for _ in $(seq 1 15); do
    runs="$(la_pref background.runs_v1)"
    if python3 -c '
import json, sys
r = json.loads(sys.argv[1])[0]
sys.exit(0 if r["enumerated"] == 0 and r["saved"] == 1 else 1)' "$runs" 2>/dev/null; then
      ok=1
      break
    fi
    sleep 1
  done
  [[ -n "$ok" ]] || la_fail "background run: its record does not show a scan that listed nothing and a save ($runs)"
  echo "==> 1. passed: one meal dated $b_date, saved by a background run whose scan listed nothing"

  echo "==> 2. Live watcher, the app open: $e_name saved with an old date"
  la_launch
  sleep 10 # the launch catch-up runs first, and finds nothing new
  [[ "$(la_eval package:calorie_tracker/services/photo/background_time.dart \
    "appEngineBackgrounded()")" == *'=> false'* ]] || la_fail "the app is not in the foreground"
  cp "$LA_WORK/$e_name" "$cont/tmp/$e_name"
  # Saved from inside the app, with its capture time: what the Meta AI app
  # does, and a change the app's own library observer is told about.
  la_eval package:calorie_tracker/services/photo/photo_library.dart \
    "PhotoManager.editor.saveImageWithPath('$cont/tmp/$e_name', title: '$e_name', creationDate: DateTime.now().subtract(const Duration(hours: 53)))"
  la_wait_meals 2 "$e_date" "live watcher"
  echo "==> 2. passed: one meal dated $e_date, the app open throughout"
  echo "==> late_import_app passed"
  rm -rf "$LA_WORK"
}

if [[ "${1:-}" == "--scenario" ]]; then
  case "${2:-}" in
    late_import_native) run_late_import_native; exit $? ;;
    late_import_app) run_late_import_app; exit $? ;;
    *) echo "unknown scenario: ${2:-} (known: late_import_native, late_import_app)" >&2; exit 2 ;;
  esac
fi

ENV_FILE="${1:?usage: run_e2e_ios.sh <env-file with E2E_GEMINI_KEY=...> | --scenario late_import_native|late_import_app}"
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
