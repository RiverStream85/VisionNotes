# Upstream provenance

The Vendor sources are copied from Apple MLX Swift LM 2.31.3, commit `25b00d4e22e61ec9c41efda47990cd2084ec87ff`, under the accompanying MIT license.

Qwen3VL.swift is modified to use FirebirdFusedAttention for batch-one single-token decode. Prefill and the vision encoder retain upstream MLX implementations. RMSNorm here means Qwen3-VL query/key per-head RMSNorm; input/post-attention layer normalization and QKV/output projections remain separate. No speedup claim is made without device measurement.

Image preprocessing is capped at 524,288 pixels and uses the existing sRGB conversion helper before resize/normalization. Only the Qwen3-VL model and its shared media helpers are vendored; the rest comes from pinned Swift packages.

The runtime uses structured `UserInput(chat:)` so both the image list and template receive the image. The pinned `prompt:images:` shortcut sets a property whose observer does not run during initialization, leaving its stored images empty. Runtime preparation now rejects a missing processed image. Decode uses Qwen VL temperature 0.7, top-p 0.8, top-k 20 and presence penalty 1.5. A small adapter flattens only the penalty processor's prompt view, avoiding the pinned token ring's assumption that the first dimension is the token count. Generation accepts success only on an explicit stop reason; cancellation and length exhaustion are not successful transcriptions.

Regression inputs and downloaded checkpoints stay in ignored development storage, never in the app bundle or source control. Generated test transcripts are developer artifacts; they do not change the app's encrypted storage path.

After a confirmed iPhone memory termination during first-token generation, vision blocks and language prefill layers are evaluated incrementally to release intermediate graphs. The vocabulary projection uses only the final prompt position (generation does not consume earlier logits). GPU buffer cache is capped at 32 MiB. This model’s upstream `prepare` ignores `windowSize`; a small iterator prefill setting alone is not a memory bound.
