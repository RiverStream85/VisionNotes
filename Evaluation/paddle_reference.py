"""Dump PaddleOCR-VL reference tensors from mlx-vlm for the Swift port.

    .venv/bin/python Evaluation/paddle_reference.py IMAGE PROMPT OUT.safetensors [MAX_TOKENS]

Writes the prompt ids, processor pixels and grid, projected vision features,
first-token logits and MAX_TOKENS (default 48) greedy token ids, which
PaddleOCRVLTests compares against. Position-embedding interpolation is patched
to torch's bilinear (align_corners=False, source index clamped at 0), which the
HF model uses and the Swift port implements; pass --no-patch for mlx-vlm's own.
"""
import sys
from pathlib import Path

import mlx.core as mx
import numpy as np
from PIL import Image

import mlx_vlm.models.paddleocr_vl.vision as V

PATCH = "--no-patch" not in sys.argv
args = [a for a in sys.argv[1:] if a != "--no-patch"]


def torch_bilinear(image, new_height, new_width, align_corners=False):
    h_in, w_in = image.shape[0], image.shape[1]

    def axis(n_out, n_in):
        pos = mx.maximum((mx.arange(n_out).astype(mx.float32) + 0.5) * (n_in / n_out) - 0.5, 0)
        lo = mx.floor(pos).astype(mx.int32)
        hi = mx.minimum(lo + 1, n_in - 1)
        return lo, hi, pos - lo

    r0, r1, rw = axis(new_height, h_in)
    c0, c1, cw = axis(new_width, w_in)
    img = image.astype(mx.float32)
    top = img[r0] * (1 - rw)[:, None, None] + img[r1] * rw[:, None, None]
    return top[:, c0] * (1 - cw)[None, :, None] + top[:, c1] * cw[None, :, None]


if PATCH:
    V.bilinear_interpolate = torch_bilinear

from mlx_vlm import load, stream_generate  # noqa: E402
from mlx_vlm.prompt_utils import apply_chat_template  # noqa: E402

image_path, prompt_text, out = args[0], args[1], Path(args[2])
max_tokens = int(args[3]) if len(args) > 3 else 48
model, processor = load("mlx-community/PaddleOCR-VL-1.5-4bit")
prompt = apply_chat_template(processor, model.config, prompt_text, num_images=1)
image = Image.open(image_path).convert("RGB")
inputs = processor(images=[image], text=[prompt])
input_ids = mx.array(np.array(inputs["input_ids"]))
pixel_values = mx.array(np.array(inputs["pixel_values"]))
grid = mx.array(np.array(inputs["image_grid_thw"]))

features = model.visual(pixel_values.astype(model.visual.embeddings.patch_embedding.weight.dtype), grid)
logits = model(input_ids, pixel_values, image_grid_thw=grid).logits[:, -1, :].astype(mx.float32)
mx.eval(features, logits)

# Greedy continuation token ids, no processors, for a token-level comparison.
model.language_model._position_ids = None
model.language_model._rope_deltas = None
tokens = [result.token for result in stream_generate(
    model, processor, prompt, image=[image], max_tokens=max_tokens, temperature=0.0)]
# The final stream result repeats the last token.
tokens = tokens[:max_tokens]
mx.save_safetensors(str(out), {
    "input_ids": input_ids.astype(mx.int32),
    "pixel_values": pixel_values.astype(mx.float32),
    "image_grid_thw": grid.astype(mx.int32),
    "features": features.astype(mx.float32),
    "logits": logits,
    "greedy": mx.array(tokens, dtype=mx.int32),
})
print("top5", mx.argsort(-logits[0])[:5].tolist())
print(processor.tokenizer.decode(tokens))
