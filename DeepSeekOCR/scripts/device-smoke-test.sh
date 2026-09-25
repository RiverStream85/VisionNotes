#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
RESULT_DIR="$PROJECT_DIR/Results"
VISION_MODE=${VISION_MODE:-accurate}
if [[ "$VISION_MODE" == "fast" ]]; then
  REPORT_PATH="$RESULT_DIR/device-smoke-test-fast.md"
else
  REPORT_PATH="$RESULT_DIR/device-smoke-test.md"
fi
DEVICE_JSON=$(mktemp -t deepseek-ocr-smoke-devices.XXXXXX)
TEMP_REPORT=$(mktemp -t deepseek-ocr-smoke-report.XXXXXX)
COPY_LOG=$(mktemp -t deepseek-ocr-smoke-copy.XXXXXX)
SMOKE_RUN_ID=$(/usr/bin/uuidgen)
trap 'rm -f "$DEVICE_JSON" "$TEMP_REPORT" "$COPY_LOG"' EXIT

if [[ "$VISION_MODE" != "accurate" && "$VISION_MODE" != "fast" ]]; then
  echo "VISION_MODE must be accurate or fast." >&2
  exit 64
fi

xcrun devicectl list devices --json-output "$DEVICE_JSON" >/dev/null
DEVICE_SELECTOR=${DEVICE_ID:-}
read -r DEVICE_ID DEVELOPER_MODE BOOT_STATE TUNNEL_STATE < <(/usr/bin/python3 - "$DEVICE_JSON" "$DEVICE_SELECTOR" <<'PY'
import json
import sys

devices = json.load(open(sys.argv[1]))["result"]["devices"]
ios = [device for device in devices
       if device.get("hardwareProperties", {}).get("platform") == "iOS"
       and device.get("connectionProperties", {}).get("pairingState") == "paired"]
selector = sys.argv[2]
if selector:
    ios = [device for device in ios if selector in {
        device.get("identifier"),
        device.get("hardwareProperties", {}).get("udid"),
        device.get("deviceProperties", {}).get("name"),
    }]
if not ios:
    raise SystemExit("No matching paired iPhone is available.")
if not selector and len(ios) > 1:
    raise SystemExit("Multiple paired iPhones are available; set DEVICE_ID explicitly.")
device = ios[0]
print("{}\t{}\t{}\t{}".format(
    device.get("hardwareProperties", {}).get("udid", ""),
    device.get("deviceProperties", {}).get("developerModeStatus", "unknown"),
    device.get("deviceProperties", {}).get("bootState", "unknown"),
    device.get("connectionProperties", {}).get("tunnelState", "unknown")))
PY
)

if [[ -z "$DEVICE_ID" || "$DEVELOPER_MODE" != "enabled" ]]; then
  echo "The selected iPhone is not ready (Developer Mode: $DEVELOPER_MODE)." >&2
  exit 2
fi
if [[ "$BOOT_STATE" != "booted" || "$TUNNEL_STATE" != "connected" ]]; then
  echo "The iPhone is not ready (boot: $BOOT_STATE, developer tunnel: $TUNNEL_STATE)." >&2
  echo "Unlock it, reconnect USB, accept Trust prompts, and keep the screen awake." >&2
  exit 2
fi

mkdir -p "$RESULT_DIR"
rm -f "$REPORT_PATH"

LAUNCH_ARGUMENTS=(--auto-ocr-test --smoke-run-id "$SMOKE_RUN_ID")
if [[ "$VISION_MODE" == "fast" ]]; then
  LAUNCH_ARGUMENTS+=(--fast-ocr-test)
fi

xcrun devicectl device process launch \
    --device "$DEVICE_ID" \
    --terminate-existing \
    com.visionnotes.DeepSeekOCR \
    "${LAUNCH_ARGUMENTS[@]}"

for ((attempt = 1; attempt <= 120; attempt++)); do
  sleep 5
  rm -f "$TEMP_REPORT"
  if xcrun devicectl device copy from \
      --device "$DEVICE_ID" \
      --source Documents/deepseek-ocr-smoke-test.md \
      --destination "$TEMP_REPORT" \
      --domain-type appDataContainer \
      --domain-identifier com.visionnotes.DeepSeekOCR \
      --timeout 10 >"$COPY_LOG" 2>&1; then
    if ! rg -q -F -x -- "- Run ID: $SMOKE_RUN_ID" "$TEMP_REPORT"; then
      continue
    fi
    if rg -q -F -x -- '- Status: PASS' "$TEMP_REPORT"; then
      cp "$TEMP_REPORT" "$REPORT_PATH"
      cat "$REPORT_PATH"
      exit 0
    fi
    if rg -q -F -x -- '- Status: FAIL' "$TEMP_REPORT"; then
      cp "$TEMP_REPORT" "$REPORT_PATH"
      cat "$REPORT_PATH" >&2
      exit 1
    fi
  fi
done

if [[ -s "$TEMP_REPORT" ]] && \
    rg -q -F -x -- "- Run ID: $SMOKE_RUN_ID" "$TEMP_REPORT"; then
  cp "$TEMP_REPORT" "$REPORT_PATH"
fi
echo "Timed out after 10 minutes waiting for the on-device OCR report." >&2
echo "Expected smoke run ID: $SMOKE_RUN_ID" >&2
exit 4
