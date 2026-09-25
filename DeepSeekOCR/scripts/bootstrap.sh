#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
VENDOR_DIR="$PROJECT_DIR/Vendor"
MODEL_DIR="$PROJECT_DIR/ModelAssets"
RUNTIME_TAG=b10236
RUNTIME_ZIP="$VENDOR_DIR/llama-$RUNTIME_TAG-xcframework.zip"
MODEL_REVISION=d08e5af400c64fa8a9b89b04ba373b600b02e05d

mkdir -p "$VENDOR_DIR" "$MODEL_DIR"

download() {
  local url=$1
  local output=$2
  local expected_size=$3
  local expected_sha256=$4
  local partial="$output.download"

  verify_file() {
    local candidate=$1
    [[ -f "$candidate" ]] || return 1
    local size
    size=$(stat -f '%z' "$candidate" 2>/dev/null || stat -c '%s' "$candidate")
    [[ "$size" == "$expected_size" ]] || return 1
    local digest
    digest=$(shasum -a 256 "$candidate" | awk '{print $1}')
    [[ "$digest" == "$expected_sha256" ]]
  }

  if verify_file "$output"; then
    echo "Already present: $output"
    return
  fi

  if [[ -f "$partial" ]]; then
    local partial_size
    partial_size=$(stat -f '%z' "$partial" 2>/dev/null || stat -c '%s' "$partial")
    if (( partial_size >= expected_size )); then
      rm -f "$partial"
    fi
  fi

  curl -L --fail --retry 5 --retry-delay 2 --continue-at - --output "$partial" "$url"
  if ! verify_file "$partial"; then
    echo "Checksum or size validation failed for $partial" >&2
    exit 1
  fi
  mv -f "$partial" "$output"
}

download \
  "https://github.com/ggml-org/llama.cpp/releases/download/$RUNTIME_TAG/llama-$RUNTIME_TAG-xcframework.zip" \
  "$RUNTIME_ZIP" \
  267309765 \
  10e577a3f056a9d9afe7a9523e5744907f67f96256a72b7dcb0b3e924d009b4c

if [[ ! -d "$VENDOR_DIR/llama.xcframework" ]]; then
  ditto -x -k "$RUNTIME_ZIP" "$VENDOR_DIR"
  if [[ -d "$VENDOR_DIR/build-apple/llama.xcframework" ]]; then
    mv "$VENDOR_DIR/build-apple/llama.xcframework" "$VENDOR_DIR/llama.xcframework"
  fi
fi

download \
  "https://huggingface.co/sabafallah/DeepSeek-OCR-2-GGUF/resolve/$MODEL_REVISION/deepseek-ocr-2-Q4_K_M.gguf" \
  "$MODEL_DIR/deepseek-ocr-2-Q4_K_M.gguf" \
  1950326688 \
  2b5625a1d649670fa4300a1ca139869850a86e9f3ad5b8e389e2133a210b139d
download \
  "https://huggingface.co/sabafallah/DeepSeek-OCR-2-GGUF/resolve/$MODEL_REVISION/mmproj-deepseek-ocr-2-q8_0.gguf" \
  "$MODEL_DIR/mmproj-deepseek-ocr-2-q8_0.gguf" \
  512537792 \
  46efe1304f581869f3b067eb77b1151dc0daf32bc25ef644fc7d505f4153a545

echo "Runtime and models are ready."
