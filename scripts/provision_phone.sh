#!/usr/bin/env bash
# One-click phone setup (2026-09-28).
#
# Builds the app's bitewise://setup link from a PRIVATE env file and hands
# it to a connected phone — iPhone via `devicectl --payload-url`, Android via
# adb — so nobody types a server address or a 48-character upload key on a
# phone. With no phone attached it prints a QR to scan with the camera.
#
# Env file (default ~/.bitewise/server.env, chmod 600, NOT in the repo):
#   SERVER_URL=http://your.server        # origin only; the app appends /api/...
#   UPLOAD_KEY=...                       # the server's ANDROID_API_KEY
#   BACKEND=claude                       # claude | glm | doubao (optional)
#
# Usage: scripts/provision_phone.sh [--qr | --print]
# The link carries the upload key: it is never echoed unless you ask (--print).
set -euo pipefail

ENV_FILE="${BITEWISE_SERVER_ENV:-$HOME/.bitewise/server.env}"
[[ -f "$ENV_FILE" ]] || { echo "missing $ENV_FILE — see the header of this script" >&2; exit 1; }
SERVER_URL=""; UPLOAD_KEY=""; BACKEND="claude"
# shellcheck disable=SC1090
source "$ENV_FILE"
[[ -n "$SERVER_URL" && -n "$UPLOAD_KEY" ]] || { echo "SERVER_URL and UPLOAD_KEY are required in $ENV_FILE" >&2; exit 1; }

urlenc() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
LINK="bitewise://setup?server=$(urlenc "$SERVER_URL")&key=$(urlenc "$UPLOAD_KEY")&backend=$(urlenc "$BACKEND")"
IOS_BUNDLE="dev.calorietracker.calorieTracker"
ANDROID_PKG="dev.calorietracker.calorie_tracker"

print_qr() {
  if python3 -c 'import qrcode' 2>/dev/null; then
    python3 -c 'import qrcode, sys; q = qrcode.QRCode(border=1); q.add_data(sys.argv[1]); q.make(); q.print_ascii(invert=True)' "$LINK"
    echo "Scan with the phone camera, then tap the banner to open it in the app."
  else
    echo "No python 'qrcode' module (pip install qrcode). Re-run with --print to get the link text." >&2
    exit 2
  fi
}

case "${1:-auto}" in
  --print) echo "$LINK"; exit 0 ;;
  --qr) print_qr; exit 0 ;;
esac

# iPhone: the first paired iOS device devicectl can see.
if command -v xcrun >/dev/null 2>&1; then
  TMP=$(mktemp); xcrun devicectl list devices --json-output "$TMP" >/dev/null 2>&1 || true
  UDID=$(python3 - "$TMP" <<'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for dev in d.get("result", {}).get("devices", []):
    hw = dev.get("hardwareProperties", {}); cp = dev.get("connectionProperties", {})
    if hw.get("platform") == "iOS" and cp.get("pairingState") == "paired":
        print(dev.get("identifier", "")); break
PYEOF
)
  rm -f "$TMP"
  if [[ -n "${UDID:-}" ]]; then
    echo "iPhone $UDID: opening the app with the setup link (confirm on the phone)…"
    xcrun devicectl device process launch --device "$UDID" --payload-url "$LINK" "$IOS_BUNDLE" >/dev/null
    echo "Done — tap 使用这台服务器 / Use this server on the phone."
    exit 0
  fi
fi

# Android: the first adb device.
if command -v adb >/dev/null 2>&1 && adb devices | awk 'NR>1 && $2=="device"{f=1} END{exit !f}'; then
  echo "Android: opening the app with the setup link (confirm on the phone)…"
  adb shell am start -a android.intent.action.VIEW -d "$LINK" "$ANDROID_PKG" >/dev/null
  echo "Done — tap 使用这台服务器 / Use this server on the phone."
  exit 0
fi

echo "No phone attached — scan this instead:"
print_qr
