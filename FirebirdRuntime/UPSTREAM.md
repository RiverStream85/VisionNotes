# Upstream provenance

The Vendor sources are copied from Apple MLX Swift LM 2.31.3, commit `25b00d4e22e61ec9c41efda47990cd2084ec87ff`, under the accompanying MIT license.

Qwen3VL.swift is modified so batch-one single-token decode can opt into FirebirdFusedAttention (`setDecodeAttention`); the default remains MLX attention. Prefill and the vision encoder retain upstream MLX implementations, except that a single image skips the all-zero dense vision attention mask. RMSNorm here means Qwen3-VL query/key per-head RMSNorm; input/post-attention layer normalization and QKV/output projections remain separate. No speedup claim is made without device measurement.

The image pixel cap is no longer hard-coded in the vendored processor; the runtime writes the device budget's `max_pixels` into the decoded preprocessor configuration. Preprocessing uses the existing sRGB conversion helper before resize/normalization. Only the Qwen3-VL model and its shared media helpers are vendored; the rest comes from pinned Swift packages.

The runtime uses structured `UserInput(chat:)` so both the image list and template receive the image. The pinned `prompt:images:` shortcut sets a property whose observer does not run during initialization, leaving its stored images empty. Runtime preparation now rejects a missing processed image. Decode is greedy by default (`FirebirdCore/FirebirdRecipe.swift`). Any penalty sees generated tokens only; prompt tokens never enter its window, which also avoids the pinned token ring's assumption about batched prompt shape. Generation accepts success only on an explicit stop reason; cancellation and length exhaustion are not successful transcriptions.

Regression inputs and downloaded checkpoints stay in ignored development storage, never in the app bundle or source control. Generated test transcripts are developer artifacts; they do not change the app's encrypted storage path.

After a confirmed iPhone memory termination during first-token generation, vision blocks and language prefill layers are evaluated incrementally to release intermediate graphs. Those evaluations are skipped once the task is cancelled, and `prepare` then throws, so no further GPU work is submitted. The vocabulary projection uses only the final prompt position (generation does not consume earlier logits). MLX memory and buffer-cache limits come from the device budget. This model’s upstream `prepare` ignores `windowSize`; a small iterator prefill setting alone is not a memory bound.
