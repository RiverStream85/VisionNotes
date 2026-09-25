#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
FRAMEWORK_DIR="$PROJECT_DIR/Vendor/llama.xcframework/macos-arm64_x86_64"
BUILD_DIR="$PROJECT_DIR/build"
RESULT_DIR="$PROJECT_DIR/Results"
TEXT_MODEL="$PROJECT_DIR/ModelAssets/deepseek-ocr-2-Q4_K_M.gguf"
VISION_MODEL="$PROJECT_DIR/ModelAssets/mmproj-deepseek-ocr-2-q8_0.gguf"
FIXTURE="$PROJECT_DIR/Fixtures/math-ocr-test.png"
REPORT="$RESULT_DIR/mac-native-smoke.md"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "The native Metal smoke test must run on macOS." >&2
  exit 2
fi

"$SCRIPT_DIR/bootstrap.sh"
mkdir -p "$BUILD_DIR" "$RESULT_DIR"

COMMON_FLAGS=(
  -std=c++17
  -O2
  -I"$PROJECT_DIR/Bridge"
  -I"$FRAMEWORK_DIR/llama.framework/Headers"
  -F"$FRAMEWORK_DIR"
  -framework llama
  -framework Foundation
  -framework Metal
  -framework Accelerate
  -Wl,-rpath,@loader_path/../Vendor/llama.xcframework/macos-arm64_x86_64
)

xcrun clang++ "${COMMON_FLAGS[@]}" \
  -x objective-c++ "$PROJECT_DIR/Bridge/DeepSeekOCRBridge.mm" \
  -x c++ "$PROJECT_DIR/Tools/bridge-smoke.cpp" \
  -o "$BUILD_DIR/bridge-smoke"

xcrun clang++ "${COMMON_FLAGS[@]}" \
  -x objective-c++ "$PROJECT_DIR/Bridge/DeepSeekOCRBridge.mm" \
  -x c++ "$PROJECT_DIR/Tools/bridge-cancel-smoke.cpp" \
  -o "$BUILD_DIR/bridge-cancel-smoke"

"$BUILD_DIR/bridge-smoke" \
  "$TEXT_MODEL" "$VISION_MODEL" "$FIXTURE" 2>&1 | tee "$REPORT"
python3 "$PROJECT_DIR/Tools/verify-math-output.py" "$REPORT"
"$BUILD_DIR/bridge-cancel-smoke" \
  "$TEXT_MODEL" "$VISION_MODEL" "$FIXTURE"

echo "Native OCR and cancellation smoke tests passed. Report: $REPORT"
