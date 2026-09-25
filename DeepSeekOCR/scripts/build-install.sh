#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
DERIVED_DIR="$PROJECT_DIR/DerivedData"

cd "$PROJECT_DIR"
"$SCRIPT_DIR/bootstrap.sh"
EXISTING_TEAM=
if [[ -d DeepSeekOCR.xcodeproj ]]; then
  EXISTING_TEAM=$(xcodebuild \
    -project DeepSeekOCR.xcodeproj \
    -scheme DeepSeekOCR \
    -sdk iphoneos \
    -showBuildSettings 2>/dev/null | \
    awk -F ' = ' '/^[[:space:]]*DEVELOPMENT_TEAM = / { print $2; exit }')
fi
if [[ ! -d DeepSeekOCR.xcodeproj || "${REGENERATE_PROJECT:-0}" == "1" ]]; then
  xcodegen generate
fi

DEVICE_JSON=$(mktemp -t deepseek-ocr-devices.XXXXXX)
trap 'rm -f "$DEVICE_JSON"' EXIT
xcrun devicectl list devices --json-output "$DEVICE_JSON" >/dev/null

DEVICE_SELECTOR=${DEVICE_ID:-}
read -r DEVICE_ID DEVELOPER_MODE BOOT_STATE TUNNEL_STATE < <(/usr/bin/python3 - "$DEVICE_JSON" "$DEVICE_SELECTOR" <<'PY'
import json
import sys

devices = json.load(open(sys.argv[1]))["result"]["devices"]
ios = [device for device in devices
       if device.get("hardwareProperties", {}).get("platform") == "iOS"
       and device.get("connectionProperties", {}).get("pairingState") == "paired"]
if not ios:
    raise SystemExit("No paired iPhone is available.")
selector = sys.argv[2]
if selector:
    ios = [device for device in ios if selector in {
        device.get("identifier"),
        device.get("hardwareProperties", {}).get("udid"),
        device.get("deviceProperties", {}).get("name"),
    }]
    if not ios:
        raise SystemExit(f"No paired iPhone matches DEVICE_ID={selector!r}.")
elif len(ios) > 1:
    raise SystemExit("Multiple paired iPhones are available; set DEVICE_ID explicitly.")
device = ios[0]
udid = device.get("hardwareProperties", {}).get("udid")
if not udid:
    raise SystemExit("The selected iPhone did not report a hardware UDID.")
mode = device.get("deviceProperties", {}).get("developerModeStatus", "unknown")
boot = device.get("deviceProperties", {}).get("bootState", "unknown")
tunnel = device.get("connectionProperties", {}).get("tunnelState", "unknown")
print(f"{udid}\t{mode}\t{boot}\t{tunnel}")
PY
)

if [[ "$DEVELOPER_MODE" != "enabled" ]]; then
  echo "Developer Mode is $DEVELOPER_MODE on the selected iPhone." >&2
  echo "Enable Settings > Privacy & Security > Developer Mode, reboot, and confirm on-device." >&2
  exit 2
fi
if [[ "$BOOT_STATE" != "booted" || "$TUNNEL_STATE" != "connected" ]]; then
  echo "The iPhone is not ready (boot: $BOOT_STATE, developer tunnel: $TUNNEL_STATE)." >&2
  echo "Unlock it, reconnect USB, accept Trust prompts, and keep the screen awake." >&2
  exit 2
fi

TEAM_ID=${DEVELOPMENT_TEAM:-$EXISTING_TEAM}
if [[ -z "$TEAM_ID" ]]; then
  TEAM_ID=$(xcodebuild \
    -project DeepSeekOCR.xcodeproj \
    -scheme DeepSeekOCR \
    -sdk iphoneos \
    -showBuildSettings 2>/dev/null | \
    awk -F ' = ' '/^[[:space:]]*DEVELOPMENT_TEAM = / { print $2; exit }')
fi

if [[ -z "$TEAM_ID" ]]; then
  IDENTITY_TEAMS=$(security find-identity -v -p codesigning 2>/dev/null | \
    sed -nE 's/.*"Apple Development:.*\(([[:alnum:]]+)\)".*/\1/p' | \
    sort -u || true)
  IDENTITY_TEAM_COUNT=$(printf '%s\n' "$IDENTITY_TEAMS" | \
    awk 'NF { count += 1 } END { print count + 0 }')
  if [[ "$IDENTITY_TEAM_COUNT" == "1" ]]; then
    TEAM_ID=$(printf '%s\n' "$IDENTITY_TEAMS" | awk 'NF { print; exit }')
  fi
fi

if [[ -z "$TEAM_ID" ]]; then
  echo "No Xcode development team is configured." >&2
  echo "Add an Apple ID in Xcode > Settings > Accounts, then select its Personal Team in Signing & Capabilities." >&2
  exit 3
fi

xcodebuild \
  -project DeepSeekOCR.xcodeproj \
  -scheme DeepSeekOCR \
  -configuration Release \
  -destination "id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED_DIR" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build

APP_PATH="$DERIVED_DIR/Build/Products/Release-iphoneos/DeepSeek OCR.app"
xcrun devicectl device install app --device "$DEVICE_ID" --timeout 1800 "$APP_PATH"

if [[ "${SKIP_SMOKE:-0}" == "1" ]]; then
  xcrun devicectl device process launch \
    --device "$DEVICE_ID" \
    --timeout 120 \
    com.visionnotes.DeepSeekOCR
  echo "DeepSeek OCR installed and launched on $DEVICE_ID (smoke test skipped)"
else
  DEVICE_ID="$DEVICE_ID" "$SCRIPT_DIR/device-smoke-test.sh"
  echo "DeepSeek OCR installed and passed the on-device smoke test on $DEVICE_ID"
fi
