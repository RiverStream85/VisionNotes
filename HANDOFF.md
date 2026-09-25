# Handoff — 2026-09-25

Read this first when continuing work on the Mac (kitm) with the attached iPhone 18 Pro Max.

## Repository and ownership

This repo started as Esther's (GitHub `RiverStream85`) open-source VisionNotes.
The working repo is `https://github.com/RiverStream85/VisionNotes` (remote `origin`, branch `main`).
Never push to Esther's repo; in the Linux checkout it is remote `esther` with its push URL disabled.
On kitm the clone is `~/data/project/VisionNotes`.
Branch `archive/firered-attempt` keeps an uncompiled FireRed-OCR attempt for reference only.
Other OCR experiments are archived outside the repo: `~/data/system-relocation/storage/archive/ocr-attempts-20260925` (kitm) and `~/data/project/archive/ocr-attempts-20260925` (Linux).

## What the app does now

- Library / Import tabs: Apple Vision OCR (`TextRecognitionService`) supplies the text layer (word boxes, `DocumentPage.recognizedText`); Firebird then reconstructs the visible content as Markdown + LaTeX (`DocumentPage.markdown`, via `PageReconstructing` in `Services/PageReconstructor.swift`). Readers, the editor and search use `DocumentPage.displayText` (Markdown when present, else Vision text). Firebird runs only if the model is already present (bundled or downloaded from the Academic tab) and only while the app is active (`ForegroundGPUWork`: cancelled on resign-active, restarted on return). If it fails, is busy with an Academic job, or is unavailable, the page keeps its Vision text; "Run OCR Again" retries.
- Academic tab: Firebird, the local Qwen3-VL-2B-Instruct 4-bit runtime (`FirebirdRuntime/`, MLX), producing Markdown + LaTeX and the existing PDF/HTML/LaTeX/ZIP exports.
- Recipe `recipe-4` (`FirebirdRuntime/Sources/FirebirdCore/FirebirdRecipe.swift`): prompt `qwenvl markdown` (Qwen3-VL's trained document-parsing prompt), greedy decoding, DeepSeek's no-repeat 20-gram rule on the GPU, one retry with a generated-only repetition penalty.
- Resolution and context come from available process memory (`FirebirdDeviceBudget`); default ceiling is the 1,048,576-pixel tier.
- Decode attention uses MLX SDPA; the authored Metal kernel is opt-in (`FirebirdDecodeAttention.fusedExperimental`) and was 42% slower on an M4.
- Model files are public and not encrypted. A development build bundles them (build phase "Bundle Firebird model" copies `work/FirebirdModel`); otherwise the Academic tab downloads them through a background URLSession with its own progress section, and they load in place.
- Cloud fallback: after a local failure the job waits in `awaitingCloudConsent`; the explicit confirmation passes `cloudFallbackAuthorized: true` to that one run (no persisted consent flag). `input.pdf` is built only on the cloud path.
- Notes, pages, Academic jobs and exports are plain files/SwiftData protected by iOS Data Protection; the app-level AES-GCM layer, Secure Enclave keys, temporary plaintext copies, lifecycle purge/cancel on `willResignActive` and the privacy cover were removed (owner decision, 2026-09-25). `LegacyStorageCleanup` deletes old encrypted data on launch; there are no users, so nothing is migrated.

## Measured on M4 Mac mini, Release, math fixture (`Evaluation/math-ocr-test.png`)

| Variant | CER | TTFT | Decode | Total |
| --- | --- | --- | --- | --- |
| old long prompt, 786K px | 0.451 (whole LaTeX document, 2 attempts) | 13.96 s | 46.4 tok/s | 29.8 s |
| `qwenvl markdown`, 786K px | 0.074 | 1.93 s | 48.9 tok/s | 13.9 s |
| `qwenvl markdown`, 1M px, recipe-4 | 0.067 | 2.69 s | 73.5 tok/s | 10.8 s |
| same, plain greedy | 0.067 | 2.43 s | 78.9 tok/s | 10.0 s |
| same, fused kernel | 0.068 | 2.67 s | 29.9 tok/s | 22.5 s |

Peak MLX memory was about 2.1 GiB.

## Measured on iPhone 18 Pro Max, Release, recipe-4, high tier (2026-09-25)

| Fixture | CER | TTFT | Decode | Total | Output tokens | Peak MLX |
| --- | --- | --- | --- | --- | --- | --- |
| `math-ocr-test.png` | 0.067 | 1.13 s | 74.3 tok/s | 9.13 s | 594 | 2.25 GB |
| `screenshot-ocr-test.png` | 0.063 | 1.11 s | 81.8 tok/s | 3.69 s | 211 | 2.25 GB |
| `handwriting-ocr-test.jpg` (synthetic) | 0.122 | 1.14 s | 79.7 tok/s | 3.70 s | 204 | 2.22 GB |

Model load from the bundle: 0.80 s. The phone matches or beats the M4. The earlier ~3-minute scan came from Xcode's Run action building Debug (MLX's C++ at -O0, ~4.7× slower decode); the scheme now runs Release.
Re-run with `FirebirdBenchmark` (`VisionNotes/App/FirebirdBenchmark.swift`): copy images to `Documents/Benchmark` in the app container (`xcrun devicectl device copy to --domain-type appDataContainer --domain-identifier com.visionnotes.VisionNotes ...`), then `xcrun devicectl device process launch --console --device <id> --environment-variables '{"VN_BENCHMARK":"1"}' com.visionnotes.VisionNotes`. Outputs land in `Documents/Benchmark/results.json`; score them with `TranscriptionMetrics.characterErrorRate`.
Handwriting and figures → Markdown are not good yet; the fixture is typeset, so collect handwritten samples.

## Build and install on the phone

1. `cd ~/data/project/VisionNotes && git pull`.
2. Model for bundling: `work/FirebirdModel` (git-ignored). If missing, run `python3 Tools/download_firebird_model.py` or copy `~/Library/Caches/vn/FirebirdModel`.
3. Open `VisionNotes.xcodeproj` in Xcode, scheme VisionNotes, destination iPhone 18 Pro Max (`kitp`, CoreDevice id `6F7BD7F6-37AD-5DC6-ABDC-0946531F569F`), Run.
4. Signing team is `2CXBZGAL4X`; bundle id stays `com.visionnotes.VisionNotes` (owner's choice). The app requests `com.apple.developer.kernel.increased-memory-limit`.

Signing only works from the GUI session: over SSH `security find-identity` shows 0 identities.
For unsigned compile checks over SSH: `xcodebuild build -project VisionNotes.xcodeproj -scheme VisionNotes -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`.

## Tests and evaluation

- Runtime package: `cd FirebirdRuntime && xcodebuild test -scheme FirebirdRuntime -destination 'platform=macOS,arch=arm64,name=My Mac'`. Requires the Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`, already installed on kitm).
- `FirebirdCoreTests` has no MLX dependency (also runs on Linux via `swift:6.1` Docker).
- Evaluation: `ReconstructionTests/testLocalEvaluation` reads git-ignored `work/Evaluation/config.json` (variants of attention/prompt/decoding/tier; format in the test's doc comment) and writes transcripts plus `report.json`. Run with `-configuration Release ENABLE_TESTABILITY=YES`; Debug MLX is ~3× slower.
- `Evaluation/verify-math-output.py` is DeepSeek's strict 28-check verifier; it fails on harmless style (`x^2` vs `x^{2}`), so read CER and the transcript as well.
- Pitfall: when run over SSH, xctest could not load test bundles from the external `~/data` volume ("Cannot find executable"). Put DerivedData and model copies on the internal disk (`~/Library/Caches/vn` was used).
- Pitfall: `devicectl` needs the developer tunnel up; any `xcrun devicectl device info apps --device <id>` brings it up.

## Next steps (priority order)

1. Box-emitting, resumable on-device OCR: PaddleOCR-VL-1.5 port in progress on `perf/firebird-speed` (model comparison in `Evaluation/README.md` and `Evaluation/bench_vlm.py`). Wire `reconstruct(imageData:resumingFrom:)` into the Academic and Library paths so an interrupted page continues instead of restarting.
2. Background GPU: iOS 26 `BGContinuedProcessingTask` with `requiredResources = .gpu` allows GPU work in the background only where `BGTaskScheduler.supportedResources` contains `.gpu`; in Sept 2025 Apple DTS said that was M3+ iPads only, no iPhone. Check the value on the iPhone 18 Pro Max before building on it.
3. Handwriting and figure recognition → Markdown, and a better preview (the Library readers show the Markdown source as text). Add handwritten pages with reference transcriptions to `Evaluation/`.
4. Calibrate `FirebirdDeviceBudget.fixedReserve` / `reservePerPixel` against the phone's measured peak (2.25 GB at the high tier).
5. Optional: reduce the cloud fallback to Mistral OCR alone with `include_blocks=True` (block boxes, figure crops, equation/table regions) instead of Mistral + SiliconFlow Qwen3-VL crops and merge.

## Cleanup status

Done: app-level AES-GCM and Secure Enclave key wrapping, seal-then-reopen verification, legacy plaintext migration, temporary decrypted copies and preview bookkeeping, lifecycle purge/cancel and privacy cover, duplicate `artifacts.zip` build, model-weight encryption and hashing, dead `exists()` branch, layered cloud-consent flag, confirmation before a local run, flattened error messages (`mathNoteSafeMessage` removed; `AppError` shows the underlying reason), ZIP "providerkeys" filter, eager `input.pdf`.
Background: the Academic job pauses on `.inactive`/`.background` and resumes on `.active`; Library/Import reconstruction restarts the interrupted page on return. The interrupted page restarts from its beginning.
91 unit tests and 4 UI tests pass on the iOS simulator.
