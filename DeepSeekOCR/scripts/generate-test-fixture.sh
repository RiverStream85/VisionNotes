#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
FIXTURE_DIR="$PROJECT_DIR/Fixtures"

command -v xelatex >/dev/null || { echo "xelatex is required" >&2; exit 1; }
command -v pdftocairo >/dev/null || { echo "pdftocairo is required" >&2; exit 1; }

xelatex -interaction=nonstopmode -halt-on-error -output-directory "$FIXTURE_DIR" \
  "$FIXTURE_DIR/math-ocr-test.tex"
pdftocairo -png -singlefile -r 190 \
  "$FIXTURE_DIR/math-ocr-test.pdf" "$FIXTURE_DIR/math-ocr-test"
if command -v magick >/dev/null; then
  magick "$FIXTURE_DIR/math-ocr-test.png" -trim +repage \
    -bordercolor white -border 72x72 "$FIXTURE_DIR/math-ocr-test.png"
fi

echo "Generated $FIXTURE_DIR/math-ocr-test.png"
