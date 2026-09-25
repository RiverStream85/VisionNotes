# Vision Notes

Vision Notes scans, recognizes, searches and exports notes on iOS. Ordinary Library OCR uses Apple Vision. Academic reconstruction now routes to **Firebird**, the application's local inference module using **PaddleOCR-VL-1.5, 4-bit** (it replaced Qwen3-VL-2B-Instruct on 2026-09-25; see Decoding). Firebird is not a separately trained model. Mistral OCR and SiliconFlow's Qwen3-VL-32B remain optional cloud fallbacks after explicit confirmation.

**Validation status:** the app has built and run on iPhone 17 Pro. Mac Metal numerical comparison passes all 18 float32/float16/bfloat16 and cache-boundary cases. The September 23 debugging session found and corrected a multimodal-input bug that dropped the actual image, plus a batched-prompt incompatibility in presence-penalty processing. The 24 Academic simulator tests and 4 UI tests pass in focused reruns, including real WebKit PDF export, persistence, cloud-consent boundaries, OCR editing, import and search. Full physical-device acceptance after these fixes, offline restart, handwriting accuracy, latency and peak memory still require validation. Do not claim a measured speedup or production-grade transcription accuracy.

## Repository layout

`VisionNotes/`, `FirebirdRuntime/` and the test targets are the Vision Notes app and its local MLX runtime.
`Evaluation/` holds the shared math OCR benchmark page, its reference transcription and an ordered 28-check verifier, taken from an earlier DeepSeek-OCR-2 proof of concept (see commit e5a7184; branch `archive/firered-attempt` keeps an uncompiled FireRed-OCR attempt).

## Features

- Camera scanning, photo/PDF import and on-device English/Chinese OCR.
- Searchable local library, OCR overlays and manual corrections.
- Local image-conditioned Academic reconstruction with resumable page checkpoints.
- Existing Academic exports: Markdown, LaTeX, offline HTML, semantic PDF, facsimile PDF, evidence, figures and ZIP.
- Local HTML + MathML rendering with no remote renderer or CDN.

## Local model setup and cold start

A development build can bundle the model: put the pinned files in `work/FirebirdModel` (`python3 Tools/download_firebird_model.py`) and the "Bundle Firebird model" build phase copies them into the app, which then loads them in place.
Otherwise the Academic tab's **On-device model** section downloads about **0.71 GB** from Hugging Face over Wi-Fi through a background URLSession, so the transfer continues while the screen is locked or the app is in the background.
Only public model files are downloaded; no notes, images or OCR text are sent.
`VisionNotes/Resources/FirebirdModel.lock.json` pins the model revision and file sizes (its SHA-256 values are used by the developer download tool).
Downloaded files live unencrypted in `Application Support/VisionNotes/Models/<revision>`, excluded from backup, and load in place; the weights are public, so app-level encryption would protect nothing.

The runtime uses the actual vision encoder, tokenizer, language model, KV cache and autoregressive generation.
Image resolution and context length are chosen at load time from the memory the process may use (`os_proc_available_memory`), not from a device model name.
`FirebirdCore/FirebirdDeviceBudget.swift` defines four tiers, from 393,216 pixels / 3,072 tokens up to 1,048,576 pixels / 6,144 tokens; the default ceiling is the highest tier, which on an M4 peaked at about 100 MiB more than the 786,432-pixel tier and transcribed the math fixture more accurately.
A device that cannot hold the weights plus one page reports local inference unavailable instead of risking a memory termination.
The app requests `com.apple.developer.kernel.increased-memory-limit`, so the signing team's App ID needs the Increased Memory Limit capability.
The per-pixel and fixed memory reserves in that file are uncalibrated estimates; replace them with peaks measured by the evaluation harness on each target device.
Output that hits the generation limit, or keeps repeating after a retry, is treated as incomplete and kept as a draft, not saved as a successful transcription.

Pinned conversion: [mlx-community/PaddleOCR-VL-1.5-4bit](https://huggingface.co/mlx-community/PaddleOCR-VL-1.5-4bit/tree/3404726b40ac30b6e4e3d37c504e3f96c9c6c984), Apache-2.0. The former Qwen3-VL-2B-Instruct pin is kept in `VisionNotes/Resources/QwenVLModel.lock.json` (`python3 Tools/download_firebird_model.py --model qwen3-vl`) for comparisons. The model weights are downloaded, not committed to this repository.

## Decoding

The app uses PaddleOCR-VL's plain OCR task (`FirebirdRecipe.paddleText`, prompt `OCR:`); `paddleSpotting` adds line boxes.
Qwen3-VL-2B was replaced after a dense two-column paper page: it skipped the authors and a whole abstract paragraph, then repeated one section until the context ran out, while PaddleOCR-VL read the full page in 5.7 s on an M4.
The notes below on `qwenvl markdown` apply to the retained Qwen recipe, `academicTranscription`.

The prompt is Qwen3-VL's trained document-parsing instruction, `qwenvl markdown`; a long custom instruction made the model emit a whole LaTeX document and raised character error rate on the math fixture from 0.07 to 0.45.
Pages are decoded greedily, so identical input yields identical output and can be regression-tested.
No penalty is applied to prompt tokens: LaTeX legitimately repeats `\`, `{`, `}`, `_`, `^` and `$`, and the earlier presence penalty of 1.5 over prompt plus output suppressed exactly those tokens.
DeepSeek-OCR's reference no-repeat rule (no repeated 20-gram), widened from 90 to the last 1,024 generated tokens after that paper page looped with a period of about 150 tokens, runs as lazy MLX operations on the GPU, so it does not stall decoding.
A repetition-loop detector stops a page whose tail repeats the same block (up to 1,024 characters per copy), and the page is retried once with a mild repetition penalty over the last 64 generated tokens only.
The prompt and decoding attempts live in `FirebirdCore/FirebirdRecipe.swift`; its version is part of the checkpoint identifier, so changing the recipe re-runs pages instead of reusing stale results.
The model identifier and checkpoint file names are derived from `FirebirdModel.lock.json` plus the recipe version.

## Custom Metal fusion (opt-in)

Single-token decode uses MLX's own scaled-dot-product attention by default, which works for any head layout and context length.
The authored kernel is available as `FirebirdDecodeAttention.fusedExperimental` and is numerically checked against MLX on the device's GPU before it is enabled; a failed check falls back to MLX.
It stays opt-in because its speed is unmeasured and it has known costs: it reads the KV history through a row-contiguous view, which likely copies the cache every step, runs only 16 × 128 threads, and is limited to 4,096 tokens and 128-dimensional heads.

`FirebirdRuntime/Sources/FirebirdRuntime/Kernels/FirebirdAttention.metal.txt` contains the kernel, compiled through MLX's custom-kernel API. When enabled, the vendored Qwen attention implementation calls it on batch-one, single-token decode with a standard KV cache. In one GPU dispatch it performs:

1. Query/key per-head RMSNorm.
2. Multimodal RoPE using the model's position-dependent cosines/sines.
3. Grouped-query attention scores (`QKᵀ`), stable softmax and weighted values (`PV`).

The shader uses 128 threads per query head and supports the pinned model's 16 query heads, 8 KV heads and 128-dimensional heads. It emits the rotated new key and attention result. QKV projection, input/post-attention layer normalization, cache append, output projection, vision encoding and multi-token prefill remain separate MLX operations. This is fusion of **Q/K RMSNorm + RoPE + attention**, not a claim that an entire transformer layer or its quantized projections executes in one dispatch. The batch-one attention products are the decode form of attention matrix multiplication.

The earlier synthetic 64-channel attention/formatting prototype has been removed from the application. No synthetic weight generator substitutes for the trained checkpoint.

## Privacy and storage

| Data or operation | Behavior |
| --- | --- |
| Library OCR | On-device Apple Vision |
| Academic inference | Local Qwen3-VL through Firebird |
| Model setup | Public model download only; no note upload |
| Notes, page images, OCR text, Academic jobs and exports | Plain files and SwiftData in the app container, encrypted at rest by iOS Data Protection, excluded from backup |
| Cloud providers | Separate, one-shot upload confirmation for the saved job |
| Provider credentials | ThisDeviceOnly Keychain items |

There is no app-level encryption layer: iOS Data Protection already encrypts the container at rest with a passcode-derived key, and an app-level layer only added decrypted temporary copies, lifecycle purges and slower storage.
Builds before this change kept notes in AES-GCM envelopes; `LegacyStorageCleanup` deletes that data and its Keychain keys on first launch instead of migrating it.

## Opt-in cloud fallback

When local inference is unavailable or cannot complete, the job preserves its local checkpoints and stops. The detail screen offers local retry or **Use cloud fallback…**. Confirmation covers sending the document PDF to Mistral OCR and page overviews/crops plus OCR transcripts to Qwen3-VL through SiliconFlow. Consent is consumed before provider requests begin; a later attempt requires a new confirmation. Authentication, storage-integrity and rendering errors do not authorize uploads.

Optional provider credentials are entered in **Cloud fallback keys** and stored in ThisDeviceOnly Keychain items. The repository no longer bundles `ProviderKeys.plist`. Default inference needs no provider credentials.

## Build and verify

Open `VisionNotes.xcodeproj`, choose the VisionNotes scheme and a device. The local `FirebirdRuntime` Swift package pins MLX Swift LM 2.31.3, MLX Swift 0.31.3 and Swift Transformers 1.2.0. It requires a Swift 6.1-capable Xcode and an installed Metal Toolchain. A signing team is needed for a physical iPhone.

The iOS simulator can exercise application UI/storage/export flows, but cannot validate this MLX inference path. Simulator Academic attempts report local inference unavailable without downloading weights; they never silently switch to cloud. Run actual model and kernel tests on a Metal-capable Mac or supported iPhone. Keep the app foregrounded during local reconstruction; iOS does not allow GPU work in the background.
Cancelling a job stops decoding after the current token and skips remaining prefill evaluations. Weight loading is not interruptible.

Run app tests with Command-U. The `FirebirdCoreTests` target (recipe, device budget, loop detection, metrics) has no MLX dependency. Kernel numerical tests live in the FirebirdRuntime package and compare fused/unfused outputs and KV updates for float32/float16/bfloat16 across cache boundaries. They need GPU access:

```sh
cd FirebirdRuntime
swift test --filter FusedAttentionTests
```

For a developer-only real-model reconstruction test, download the pinned assets into the ignored development cache:

```sh
python3 Tools/download_firebird_model.py
```

Then run `ReconstructionTests` with `FIREBIRD_MODEL_DIR`, `FIREBIRD_TEST_IMAGE` and `FIREBIRD_EXPECTED_LATEX` set to a local model folder, a handwritten image and a known formula fragment.
For a dataset evaluation, describe samples and optional reference transcriptions in the git-ignored `work/Evaluation/config.json` (format documented above `testLocalEvaluation`); each named variant sets the attention kernel, prompt, decoding and resolution tier, and the test writes each transcription plus a `report.json` with character error rate, time to first text, decode tokens per second, peak MLX memory and retry count. Run it in Release (`-configuration Release ENABLE_TESTABILITY=YES`); Debug MLX builds are several times slower. The application uses its own encrypted streaming installer; the developer cache is not the app storage format.

Remaining acceptance includes: a first install on Wi-Fi, an offline process restart on iPhone 17 Pro, known handwritten-math samples, checking cloud traffic is absent before consent.

## Export behavior and limitations

Recompile locally rebuilds the existing deliverables without OCR provider calls. The visible Contents block appears only when Markdown contains headings. The app does not generate native PDF bookmark trees; HTML anchor links are not guaranteed to survive WebKit PDF export. LaTeX is editable source; the bundled PDF is rendered from local HTML + MathML.

Handwriting recognition is probabilistic. Review `[unclear: ...]` markers and compare formulas with the source. Long pages can exceed the context/output limits and pause rather than complete. There is no account or cloud sync, and no latency, speedup or peak-memory claim until physical-device measurements pass.

See [ACADEMIC_OCR.md](ACADEMIC_OCR.md) and [runtime provenance](FirebirdRuntime/UPSTREAM.md).
