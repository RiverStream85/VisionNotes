# DeepSeek OCR for iOS

An offline iOS proof of concept for **DeepSeek-OCR-2 (3B MoE)**. The app accepts an
image from Photos or Files and returns local Markdown/LaTeX OCR. Inference runs on
the device through llama.cpp + Metal; no image leaves the iPhone or iPad.

## Runtime and model

- Runtime: llama.cpp `b10236` XCFramework, including `mtmd` DeepSeek-OCR-2 support.
- Text model: `sabafallah/DeepSeek-OCR-2-GGUF`, `Q4_K_M` (about 1.95 GB).
- Vision encoder: the matching `mmproj` in `Q8_0` (about 0.51 GB).
- Upstream model: `deepseek-ai/DeepSeek-OCR-2`, Apache-2.0.
- Default prompt: `<|grounding|>Convert the document to markdown.`
- Decoding: DeepSeek's generated-token-only 20-gram/window-90 rule with the
  official `<td>`/`</td>` whitelist, plus a bounded Q4 startup-loop guard that
  disables itself when visible math or table markup begins.
- Device policy: A-series GPUs keep vision flash attention and default to the
  full-detail path. M-series GPUs use the faster regular attention kernel and
  M-series iPad Pro defaults to the overview path. Both modes remain selectable.

The two GGUF files are intentionally not checked into git. `scripts/bootstrap.sh`
downloads the pinned runtime and weights into `Vendor/` and `ModelAssets/`.

## Build

On the Mac with Xcode and XcodeGen installed:

```bash
./scripts/bootstrap.sh
xcodegen generate
open DeepSeekOCR.xcodeproj
```

Select an iPhone or iPad target and run. The development build bundles both model files,
so inference remains available with Airplane Mode enabled after installation.

## Accurate and Fast vision modes

**Accurate** encodes DeepSeek-OCR-2's 1024px overview plus its 768px detail crops.
It is the default on iPhone and passed all 28 ordered math/prose checks on the
bundled fixture. **Fast** uses llama.cpp b10236's public chunk API to execute only
the 257-token overview while keeping the same loaded model and Metal context. It
is the default on Apple M-series iPad Pro and can be selected manually on iPhone.
If a future model exposes an unfamiliar chunk layout, Fast safely falls back to
Accurate rather than dropping image data.

Representative runs for the 1459×1228 dense math page:

| Device | Mode | Vision + prefill | Input tokens | Result |
|---|---:|---:|---:|---|
| M4 Mac mini | Accurate | 5.01 s | 844 | strict 28/28 |
| M4 Mac mini | Fast | 1.55 s | 268 | math semantics pass |
| iPhone 15 Pro Max | Accurate | 13.18 s | 844 | strict 28/28 |
| iPhone 15 Pro Max | Fast | 4.81 s | 268 | math semantics pass |

The final iPhone Fast run reported thermal state `fair` with Low Power Mode off;
it completed the dense 755-token page in 18.32 s including a 3.20 s cold model
load, versus 28.67 s for the final Accurate run. A dense page that emits 700+
output tokens cannot complete in one second:
at roughly 70 tokens/s, text generation alone needs about ten seconds. Fast
mainly improves time to the first generated token; small crops and short outputs
finish much sooner.

Before the first physical-device install:

1. Enable **Settings → Privacy & Security → Developer Mode** on the iPhone,
   reboot it, and confirm the prompt after reboot.
2. Add an Apple ID under **Xcode → Settings → Accounts** and select its Personal
   Team in the target's **Signing & Capabilities** pane.

For a one-command build, install, and on-device math OCR smoke test:

```bash
./scripts/build-install.sh
```

You can also pass `DEVELOPMENT_TEAM=XXXXXXXXXX` and `DEVICE_ID=...` to the script.
It validates Developer Mode before starting the large signed build, installs the
app, launches the bundled math fixture with a unique smoke-test run ID, and saves
the verified device report to `Results/device-smoke-test.md`. The command exits
nonzero if model loading, inference, report retrieval, or formula validation fails.

To reinstall and launch without running the smoke test:

```bash
SKIP_SMOKE=1 ./scripts/build-install.sh
```

After an installation, rerun only the device smoke test with:

```bash
./scripts/device-smoke-test.sh
```

The device smoke test is strict Accurate by default. Fast has a separate
semantic-equivalence gate, leaving the Accurate regression checks unchanged:

```bash
VISION_MODE=fast ./scripts/device-smoke-test.sh
```

## Math OCR fixture

`Fixtures/math-ocr-test.tex` is the gold-source test page. Regenerate its PNG with:

```bash
./scripts/generate-test-fixture.sh
```

The app bundles that PNG and exposes it through **Use math test page**. The page
contains English, Chinese, fractions, matrices, integrals, sums, a piecewise
function, Maxwell's equations, and Navier-Stokes notation.

The same native bridge can be smoke-tested on Apple Silicon macOS before device
deployment with:

```bash
./scripts/native-smoke-test.sh
```

This runs the exact bridge, validates 28 ordered prose/math conditions, rejects
truncation/startup loops, and verifies native cancellation. The checked fixture
currently produces faithful Markdown/LaTeX for every displayed equation with
the pinned Q4/Q8 model. Image preparation happens off the main thread, preserves
PNG/TIFF losslessly, and caps decoded OCR input to the model's six-tile pixel
budget and a 4608-pixel absolute edge.
