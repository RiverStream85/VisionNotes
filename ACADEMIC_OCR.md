# Academic implementation

Scan/import, source editing, comparison and the existing Academic exports remain unchanged. Firebird is the local runtime module, using the pinned Apache-2.0 Qwen3-VL-2B-Instruct 4-bit checkpoint; it is not a separately trained model.

## Request path

1. Seal normalized pages in the job store.
2. On first setup, fetch the pinned model/tokenizer assets over Wi-Fi without sending page content. Stream directly into AES-GCM chunks and verify exact byte counts/SHA-256 before writing asset receipts.
3. On later launches, open the encrypted app-container assets locally. Temporarily decrypt into protected files, load/evaluate MLX tensors and the tokenizer, then remove those files.
4. Run the actual image encoder and autoregressive decoder with greedy decoding, a repetition-loop detector and one retry. Attention uses MLX by default; the authored Metal shader is opt-in. No rule-based text formatter or synthetic weights replace the model.
5. Seal each page's generated Markdown with the pinned model revision in its checkpoint. A versioned cache filename prevents reuse of the removed attention prototype's results. A checkpoint must match the current page index and model identifier.
6. Render the existing Markdown/LaTeX/HTML/PDF/facsimile/ZIP outputs locally, then seal them. Explicit sharing materializes the selected output temporarily.

## Fusion boundary

The custom shader is `FirebirdRuntime/Sources/FirebirdRuntime/Kernels/FirebirdAttention.metal.txt`. It is disabled by default and is enabled only through `FirebirdDecodeAttention.fusedExperimental` after a numerical self-check on the device. It fuses **Q/K per-head RMSNorm, multimodal RoPE, QKᵀ attention scores, stable softmax and PV accumulation** in one dispatch for batch-one single-token decode. Quantized QKV projection, input-layer RMSNorm, cache append, output projection, the MLP and vision/prefill computations remain separate. The integration does not claim a single-dispatch full transformer layer or a measured speedup.

Image resolution and context length come from a device budget chosen from available process memory; see README. Truncation or an unbroken repetition loop is an inference failure rather than a completed transcription. Device memory/latency and handwritten-math accuracy remain to be validated on each target phone.

## Encryption and cloud consent

CryptoKit AES-GCM protects sources, OCR content, thumbnails, titles/original filenames, Academic artifacts and model chunks. File/record identity is authenticated. Model assets additionally use a pinned revision and SHA-256. Master-key wrapping uses Secure Enclave on supported hardware, with ThisDeviceOnly Keychain storage. Provider keys use Keychain; no content keys or provider secrets are bundled as plist files or logged.

An availability failure pauses the local attempt. Cloud requests require a separate explicit one-shot consent for the saved job, consumed before any Mistral or SiliconFlow request. Storage/authentication failures never trigger cloud fallback. The optional cloud path sends the PDF to Mistral OCR and images/transcripts to Qwen3-VL-32B on SiliconFlow.

Temporary plaintext is cleared after loading/rendering and at lifecycle cleanup/next launch. Persistent operational metadata remains in SwiftData. Migration does not guarantee forensic deletion of old storage blocks.

## Validation status

The original attention/formatting prototype is removed. Real-model loading/generation, the encrypted asset installer and fused attention integration are implemented in source. The custom shader passes Metal compilation. GPU numerical execution, package/app build and offline iPhone 17 Pro reconstruction have not yet passed in the current environment. See README for the exact test commands; these are still acceptance requirements, not completed claims.

## September 23 runtime corrections

Structured multimodal chat now supplies the actual image to preprocessing; the pinned convenience initializer did not. Missing image features fail explicitly. The presence-penalty adapter flattens its view of batched prompt tokens, and generation success requires an explicit stop reason. Completed checkpoints use an input-v2 identifier so stale output from the broken input path is not reused.

Mac GPU numerical checks passed all 18 dtype/cache cases. The supplied handwriting sample finishes through both original and fused attention, but recognition quality is not accepted: some subscripts and vertical connectors are wrong. Post-fix iPhone memory, cold-start/offline behavior and latency still need device acceptance. The simulator exercises UI/storage/export only; local MLX inference is reported unavailable there, without automatic cloud upload. Sustained background local generation is not implemented.
