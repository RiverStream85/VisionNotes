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
- Notes and exports are still AES-GCM encrypted at the app level (see "Cleanup" below).

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

1. Cleanup of over-defensive code (audit below). Owner wants unnecessary checks removed.
2. Default scan path: Firebird for visible content, Apple Vision kept only for the text layer (search boxes, PDF text) — owner decided.
3. Background handling: on `didEnterBackground` pause between pages and resume automatically when active (GPU work is not allowed in the background).
4. Handwriting and figure recognition → Markdown, and a better preview. Add handwritten pages with reference transcriptions to `Evaluation/`.
5. Record iPhone 18 Pro Max numbers (TTFT, tok/s, peak memory) and calibrate `FirebirdDeviceBudget.fixedReserve` / `reservePerPixel`, which are still estimates.

## Cleanup audit (not yet applied)

Clear wins:
- Seal-then-decrypt "verification" after every write: `LibraryDocument.swift:83-91,157-178`, `DocumentPage.swift:51-67`, `TextBlock.swift:47-63` (AES-GCM cannot disagree with itself).
- Legacy plaintext migration, which only matters for August dev builds: `FileStorageService.swift:263-381`, `MathNoteJobStore.swift:335-443`, `DeviceMigrationStateStore` in `SecureKeyStore.swift`, `legacy*` model columns, `DocumentStore.swift:87-114,165-184,198-201`. It also runs three fetches on every store access.
- `artifacts.zip` built twice: `AcademicDocumentRenderer.swift:57-67` and `MathNotePipeline.rebuildArchive`.
- Dead or duplicate checks: `MathNoteJobStore.exists` (both branches identical), `StoredZIPWriter` "providerkeys" filter, four copies of the path-escape guard for internally generated names, `PDFReaderView.swift:191-194`.
- Cloud consent checked 7+ times across pipeline/store/models; the explicit confirmation plus the `cloudFallbackAuthorized` parameter is enough.
- Confirmation dialog before a purely local run (`MathNotesView.swift:28-39`).

Behavior changes that improve UX:
- Lifecycle purge/cancel on `willResignActive` (`VisionNotesApp.swift`, `MathNotesViewModel.suspendForProtectedLifecycle`, observers in `MathNotesView`/`PDFReaderView`): Control Center or a notification cancels jobs and imports.
- Privacy cover flashes "locked" on every launch and inactive moment; keep `.privacySensitive()` or show it only in `.background`.
- Errors are flattened to "could not finish" (`mathNoteSafeMessage`, `EncryptedTextCodec`, `AppError.wrap`); surface real messages.

Open design question for the owner: drop app-level AES-GCM for notes entirely.
iOS Data Protection already encrypts files at rest; the app layer adds temporary decrypted copies, lifecycle purges, whole-job re-encryption on every run, decrypt-on-every-row-render and decrypt-the-library-per-search.
Replacement: plaintext SwiftData attributes and files with `completeUntilFirstUserAuthentication` (keeps background work possible), about 1,600 lines removed.
If kept, still apply the items above and replace Secure Enclave key wrapping with a plain Keychain key.
Tests that exercise removed behavior and would be deleted or adjusted: the legacy-migration tests in `FileStorageServiceTests`/`DocumentStoreTests`/`AcademicOCRTests`, the one-shot cloud-consent tests, the lifecycle purge tests (`testMaterializationStaysBlockedAfterLifecyclePurgeUntilResume`, `testLifecycleSuspensionRejectsInFlightPublicationBeforePurging`), and, if AES goes, the vault tamper/header tests and the tests that inject `EncryptedDataVault(keyProvider:)`.
