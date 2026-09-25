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

- Library / Import tabs: Apple Vision OCR (`TextRecognitionService`), fast, plain text plus word boxes; no LaTeX.
- Academic tab: Firebird, the local Qwen3-VL-2B-Instruct 4-bit runtime (`FirebirdRuntime/`, MLX), producing Markdown + LaTeX and the existing PDF/HTML/LaTeX/ZIP exports.
- Recipe `recipe-4` (`FirebirdRuntime/Sources/FirebirdCore/FirebirdRecipe.swift`): prompt `qwenvl markdown` (Qwen3-VL's trained document-parsing prompt), greedy decoding, DeepSeek's no-repeat 20-gram rule on the GPU, one retry with a generated-only repetition penalty.
- Resolution and context come from available process memory (`FirebirdDeviceBudget`); default ceiling is the 1,048,576-pixel tier.
- Decode attention uses MLX SDPA; the authored Metal kernel is opt-in (`FirebirdDecodeAttention.fusedExperimental`) and was 42% slower on an M4.
- Model files are public and not encrypted. A development build bundles them (build phase "Bundle Firebird model" copies `work/FirebirdModel`); otherwise the Academic tab downloads them through a background URLSession with its own progress section, and they load in place.
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
The owner reports the phone build works and is fast; phone numbers have not been recorded yet.
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

1. Finish the cleanup of over-defensive code (remaining items below). Owner wants unnecessary checks removed.
2. Default scan path: Firebird for visible content, Apple Vision kept only for the text layer (search boxes, PDF text) — owner decided.
3. Background handling: on `didEnterBackground` pause between pages and resume automatically when active (GPU work is not allowed in the background).
4. Handwriting and figure recognition → Markdown, and a better preview. Add handwritten pages with reference transcriptions to `Evaluation/`.
5. Record iPhone 18 Pro Max numbers (TTFT, tok/s, peak memory) and calibrate `FirebirdDeviceBudget.fixedReserve` / `reservePerPixel`, which are still estimates.

## Cleanup status

Done: app-level AES-GCM and Secure Enclave key wrapping, seal-then-reopen verification, legacy plaintext migration, temporary decrypted copies and preview bookkeeping, lifecycle purge/cancel and privacy cover, duplicate `artifacts.zip` build, model-weight encryption and hashing, dead `exists()` branch.
About 2,400 lines removed; 93 unit tests and 4 UI tests pass on the iOS simulator.

Remaining candidates:
- Cloud consent is still checked in several layers (`MathNotePipeline` run/catch branches, `MathNoteJobStore.setCloudFallbackConsent`/`consumeCloudFallbackConsent`, `MathNoteModels.allowsCloudFallback`); the explicit confirmation plus the `cloudFallbackAuthorized` parameter is enough. Tests to drop: `testCloudFallbackAuthorizationIsOneShot`, `testPersistedFlagAloneCannotAuthorizeAnUpload`, `testCancelledRetryClearsUnusedCloudAuthorization`.
- Confirmation dialog before a purely local run (`MathNotesView`, "Process … on this iPhone?").
- Errors are flattened to "could not finish" (`mathNoteSafeMessage`, `AppError.wrap`); show `localizedDescription`.
- `StoredZIPWriter` "providerkeys" filter and its test.
- `input.pdf` is built on every run but only the cloud path uses it; build it lazily in `cloudRefinements`.
- Background: the Academic job pauses on `.inactive`/`.background` (GPU work is not allowed in the background) and resumes automatically on `.active`; the interrupted page restarts from its beginning. Finer-grained resume within a page is possible future work.
