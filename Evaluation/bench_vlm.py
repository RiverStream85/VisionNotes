"""Benchmark document-OCR VLMs with Python mlx-vlm on the Evaluation fixtures.

Reports per model and fixture: time to first token (image preparation, vision
encoding and prefill), decode tokens/s, total time, peak MLX memory, prompt and
output tokens, character error rate against the Markdown reference, and, for
models that emit boxes, rough box metrics against the fixture's .lines.json:

- line recall: reference lines whose center lies in some predicted box;
- box precision: predicted boxes that contain at least one reference line center;
- mean IoU: each such box against the union of the reference lines it contains.

CER uses the Swift harness's normalization (whitespace and math delimiters
removed) after stripping code fences, HTML/DocTags markup and box annotations,
so layout formats and plain Markdown are compared on their text.

    uv venv -p 3.12 .venv && uv pip install -p .venv/bin/python mlx-vlm
    .venv/bin/python Evaluation/bench_vlm.py --models firebird deepseek-ocr --out /tmp/bench

Model weights come from the Hugging Face cache (set HF_HOME to keep them off a
small disk). Presets list the checkpoint, prompt, output format and any
input resize; add one to try another model.
"""

import argparse
import json
import os
import re
import time
import traceback
from dataclasses import dataclass, field
from pathlib import Path

import mlx.core as mx
from PIL import Image

EVALUATION = Path(__file__).resolve().parent
FIXTURES = [
    ("math-ocr-test.png", "math-ocr-reference.md"),
    ("screenshot-ocr-test.png", "screenshot-ocr-expected.md"),
    ("handwriting-ocr-test.jpg", "handwriting-ocr-expected.md"),
]

DOTS_PROMPT = """Please output the layout information from the PDF image, including each layout element's bbox, its category, and the corresponding text within the bbox.

1. Bbox format: [x1, y1, x2, y2]

2. Layout Categories: The possible categories are ['Caption', 'Footnote', 'Formula', 'List-item', 'Page-footer', 'Page-header', 'Picture', 'Section-header', 'Table', 'Text', 'Title'].

3. Text Extraction & Formatting Rules:
    - Picture: For the 'Picture' category, the text field should be omitted.
    - Formula: Format its text as LaTeX.
    - Table: Format its text as HTML.
    - All Others (Text, Title, etc.): Format their text as Markdown.

4. Constraints:
    - The output text must be the original text from the image, with no translation.
    - All layout elements must be sorted according to human reading order.

5. Final Output: The entire output must be a single JSON object.
"""


@dataclass
class Preset:
    model: str
    prompt: str
    format: str = "markdown"
    # Longest side or pixel budget applied before the processor, when the
    # model's own default would differ from how the app would run it.
    max_pixels: int | None = None
    notes: str = ""
    kwargs: dict = field(default_factory=dict)
    # Some checkpoints still reference upstream PyTorch remote code that no
    # longer imports with current transformers; mlx-vlm does not need it.
    strip_remote_code: bool = False
    # Defaults for the processor call, e.g. DeepSeek-OCR's cropping switch.
    processor_kwargs: dict = field(default_factory=dict)
    # DeepSeek-OCR's reference rule, also used by Firebird: ban a token that
    # would repeat a 20-gram seen in the last 90 generated tokens.
    no_repeat_ngram: bool = False


def no_repeat_ngram(size=20, window=90):
    """Logits processor for mlx-vlm; sees only generated tokens."""
    state = {}

    def process(tokens, logits):
        history = tokens.reshape(-1).tolist()
        start = state.setdefault("prompt", len(history))
        generated = history[start:][-window:]
        if len(generated) >= size:
            prefix = generated[-(size - 1):]
            banned = [generated[i + size - 1] for i in range(len(generated) - size + 1)
                      if generated[i:i + size - 1] == prefix]
            if banned:
                logits[..., mx.array(banned)] = -float("inf")
        return logits

    return process


def without_remote_code(repo):
    """Links a snapshot into a directory without *.py files and auto_map entries."""
    from huggingface_hub import snapshot_download

    source = Path(snapshot_download(repo))
    target = Path(os.environ.get("HF_HOME", Path.home() / ".cache/huggingface")) / "stripped" / repo.replace("/", "--")
    target.mkdir(parents=True, exist_ok=True)

    def strip(value):
        return {k: strip(v) for k, v in value.items() if k != "auto_map"} if isinstance(value, dict) else value

    for item in source.iterdir():
        link = target / item.name
        if link.is_symlink() or link.exists():
            link.unlink()
        if item.suffix == ".py":
            continue
        if item.suffix == ".json" and "auto_map" in item.read_text():
            link.write_text(json.dumps(strip(json.loads(item.read_text())), indent=2))
        else:
            link.symlink_to(item.resolve())
    return str(target)


FIREBIRD = os.path.expanduser("~/Library/Caches/vn/FirebirdModel")
PRESETS = {
    "firebird": Preset(FIREBIRD, "qwenvl markdown", max_pixels=1_048_576,
                       notes="Qwen3-VL-2B-Instruct 4-bit, app recipe prompt"),
    "firebird-standard": Preset(FIREBIRD, "qwenvl markdown", max_pixels=524_288),
    "firebird-spot": Preset(FIREBIRD, "Spotting all the text in the image with line-level, and output in JSON format.",
                            format="qwen-json", max_pixels=1_048_576),
    "deepseek-ocr": Preset("mlx-community/DeepSeek-OCR-4bit", "<|grounding|>Convert the document to markdown.",
                           format="deepseek", strip_remote_code=True),
    "deepseek-ocr-md": Preset("mlx-community/DeepSeek-OCR-4bit", "Convert the document to markdown.",
                              strip_remote_code=True),
    "deepseek-ocr-base": Preset("mlx-community/DeepSeek-OCR-4bit", "<|grounding|>Convert the document to markdown.",
                                format="deepseek", strip_remote_code=True, processor_kwargs={"cropping": False},
                                notes="1024x1024 global view only (256 visual tokens), no 640 tiles"),
    "deepseek-ocr-2": Preset("mlx-community/DeepSeek-OCR-2-4bit", "<|grounding|>Convert the document to markdown.",
                             format="deepseek", strip_remote_code=True),
    "paddleocr-vl": Preset("mlx-community/PaddleOCR-VL-1.5-4bit", "OCR:"),
    "paddleocr-vl-spot": Preset("mlx-community/PaddleOCR-VL-1.5-4bit", "Spotting:", format="paddle-spot"),
    "paddleocr-vl-spot-rp": Preset("mlx-community/PaddleOCR-VL-1.5-4bit", "Spotting:", format="paddle-spot",
                                   kwargs={"repetition_penalty": 1.05, "repetition_context_size": 64}),
    "paddleocr-vl-spot-nr": Preset("mlx-community/PaddleOCR-VL-1.5-4bit", "Spotting:", format="paddle-spot",
                                   no_repeat_ngram=True),
    "deepseek-ocr-nr": Preset("mlx-community/DeepSeek-OCR-4bit", "<|grounding|>Convert the document to markdown.",
                              format="deepseek", strip_remote_code=True, no_repeat_ngram=True),
    "deepseek-ocr-base-nr": Preset("mlx-community/DeepSeek-OCR-4bit", "<|grounding|>Convert the document to markdown.",
                                   format="deepseek", strip_remote_code=True, processor_kwargs={"cropping": False},
                                   no_repeat_ngram=True),
    "glm-ocr": Preset("mlx-community/GLM-OCR-4bit", "Text Recognition:"),
    "granite-docling": Preset("ibm-granite/granite-docling-258M-mlx", "Convert this page to docling.",
                              format="doctags"),
    "lighton-ocr-2": Preset("mlx-community/LightOnOCR-2-1B-4bit", "", max_pixels=1540 * 1540),
    "dots-ocr": Preset("mlx-community/dots.ocr-4bit", DOTS_PROMPT, format="dots"),
    "mineru-layout": Preset("mlx-community/MinerU2.5-2509-1.2B-bf16", "\nLayout Detection:", format="mineru"),
}


# --- text and box extraction -------------------------------------------------

def strip_fences(text):
    return re.sub(r"^```[a-zA-Z]*\s*$", "", text, flags=re.M)


def strip_markup(text):
    text = re.sub(r"<[^>]+>", " ", text)
    return text.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")


def parse_deepseek(text, size):
    """<|ref|>kind<|/ref|><|det|>[[x1, y1, x2, y2]]<|/det|> text ... on a 0-999 grid."""
    pattern = re.compile(r"<\|ref\|>(.*?)<\|/ref\|><\|det\|>(.*?)<\|/det\|>", re.S)
    matches = list(pattern.finditer(text))
    boxes, parts = [], []
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        body = text[match.end():end].strip()
        parts.append(body)
        for box in re.findall(r"\[(\d+), *(\d+), *(\d+), *(\d+)\]", match.group(2)):
            boxes.append([int(c) / 999 for c in box])
    plain = "\n\n".join(parts) if matches else text
    return plain, boxes


def parse_qwen_json(text, size):
    """[{"bbox_2d": [x1, y1, x2, y2], "text_content": ...}] on a 0-1000 grid."""
    body = strip_fences(text)
    boxes, parts = [], []
    for match in re.finditer(r"\{[^{}]*\}", body, re.S):
        try:
            item = json.loads(match.group(0))
        except json.JSONDecodeError:
            continue
        # Key names vary with the prompt (bbox_2d, bounding_box; text_content, line).
        box = next((v for v in item.values() if isinstance(v, list) and len(v) == 4), None)
        if box:
            boxes.append([c / 1000 for c in box])
        parts.append(next((v for v in item.values() if isinstance(v, str)), ""))
    return "\n".join(parts), boxes


def parse_dots(text, size):
    """A JSON list of {bbox, category, text} in pixels of the smart-resized input."""
    width, height = size
    factor, max_pixels, min_pixels = 28, 11_289_600, 3136
    w, h = round(width / factor) * factor, round(height / factor) * factor
    if w * h > max_pixels:
        beta = (width * height / max_pixels) ** 0.5
        w, h = int(width / beta / factor) * factor, int(height / beta / factor) * factor
    elif w * h < min_pixels:
        beta = (min_pixels / (width * height)) ** 0.5
        w, h = -(-int(width * beta) // factor) * factor, -(-int(height * beta) // factor) * factor
    body = strip_fences(text)
    try:
        items = json.loads(body)
    except json.JSONDecodeError:
        items = []
        for match in re.finditer(r"\{[^{}]*\}", body, re.S):
            try:
                items.append(json.loads(match.group(0)))
            except json.JSONDecodeError:
                pass
    boxes, parts = [], []
    for item in items if isinstance(items, list) else []:
        box = item.get("bbox")
        if box and len(box) == 4:
            boxes.append([box[0] / w, box[1] / h, box[2] / w, box[3] / h])
        parts.append(str(item.get("text", "")))
    return "\n\n".join(parts), boxes


def parse_doctags(text, size):
    """<tag><loc_x1><loc_y1><loc_x2><loc_y2>text</tag> on a 0-500 grid."""
    boxes = []
    for match in re.finditer(r"<loc_(\d+)><loc_(\d+)><loc_(\d+)><loc_(\d+)>", text):
        boxes.append([int(v) / 500 for v in match.groups()])
    plain = re.sub(r"<loc_\d+>", "", text)
    return strip_markup(plain), boxes


def parse_paddle_spot(text, size):
    """Text followed by <|LOC_n|> tokens: four corner points on a 0-1000 grid."""
    boxes, parts = [], []
    for match in re.finditer(r"([^<]*)((?:<\|LOC_\d+\|>){8})", text):
        values = [int(v) / 1000 for v in re.findall(r"LOC_(\d+)", match.group(2))]
        xs, ys = values[0::2], values[1::2]
        boxes.append([min(xs), min(ys), max(xs), max(ys)])
        parts.append(match.group(1).strip())
    if not parts:
        return re.sub(r"<\|LOC_\d+\|>", "", text), []
    return "\n".join(parts), boxes


def parse_mineru(text, size):
    """<|box_start|>x1 y1 x2 y2<|box_end|><|ref_start|>kind<|ref_end|> on a 0-1000 grid (layout only)."""
    boxes = [[int(v) / 1000 for v in m.groups()]
             for m in re.finditer(r"<\|box_start\|>(\d+) (\d+) (\d+) (\d+)<\|box_end\|>", text)]
    return "", boxes


PARSERS = {
    "markdown": lambda text, size: (text, []),
    "deepseek": parse_deepseek,
    "qwen-json": parse_qwen_json,
    "dots": parse_dots,
    "doctags": parse_doctags,
    "paddle-spot": parse_paddle_spot,
    "mineru": parse_mineru,
}


# --- metrics -------------------------------------------------------------------

def normalized(text):
    for delimiter in ["$$", "\\[", "\\]", "\\(", "\\)", "$"]:
        text = text.replace(delimiter, "")
    return "".join(text.split())


def edit_distance(a, b):
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i] + [0] * len(b)
        for j, cb in enumerate(b, 1):
            current[j] = min(previous[j - 1] + (ca != cb), previous[j] + 1, current[j - 1] + 1)
        previous = current
    return previous[-1]


def character_error_rate(prediction, reference):
    p, r = normalized(prediction), normalized(reference)
    return edit_distance(p, r) / max(1, len(r))


def box_metrics(boxes, lines):
    if not boxes or not lines:
        return None

    def inside(point, box, tolerance=0.01):
        return box[0] - tolerance <= point[0] <= box[2] + tolerance and box[1] - tolerance <= point[1] <= box[3] + tolerance

    def area(box):
        return max(0, box[2] - box[0]) * max(0, box[3] - box[1])

    centers = [((l["box"][0] + l["box"][2]) / 2, (l["box"][1] + l["box"][3]) / 2) for l in lines]
    recall = sum(any(inside(c, b) for b in boxes) for c in centers) / len(lines)
    ious = []
    for box in boxes:
        covered = [l["box"] for l, c in zip(lines, centers) if inside(c, box)]
        if not covered:
            continue
        union = [min(b[0] for b in covered), min(b[1] for b in covered),
                 max(b[2] for b in covered), max(b[3] for b in covered)]
        overlap = [max(box[0], union[0]), max(box[1], union[1]), min(box[2], union[2]), min(box[3], union[3])]
        intersection = area(overlap)
        ious.append(intersection / (area(box) + area(union) - intersection))
    return {"lineRecall": round(recall, 3), "boxPrecision": round(len(ious) / len(boxes), 3),
            "meanIoU": round(sum(ious) / len(ious), 3) if ious else 0.0, "boxes": len(boxes)}


# --- generation ------------------------------------------------------------------

def prepared_image(path, max_pixels):
    image = Image.open(path).convert("RGB")
    if max_pixels and image.width * image.height > max_pixels:
        scale = (max_pixels / (image.width * image.height)) ** 0.5
        image = image.resize((int(image.width * scale), int(image.height * scale)), Image.BICUBIC)
    return image


def run(name, preset, max_tokens, out):
    from mlx_vlm import load, stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template

    started = time.perf_counter()
    model, processor = load(without_remote_code(preset.model) if preset.strip_remote_code else preset.model)
    if preset.processor_kwargs:
        base = type(processor)
        defaults = preset.processor_kwargs
        processor.__class__ = type(base.__name__, (base,), {
            "__call__": lambda self, *args, **kwargs: base.__call__(self, *args, **{**defaults, **kwargs})})
    load_seconds = time.perf_counter() - started
    # Warm up kernels once so the first fixture's TTFT is not a compile time.
    warmup = apply_chat_template(processor, model.config, preset.prompt, num_images=1)
    for _ in stream_generate(model, processor, warmup, image=[prepared_image(EVALUATION / FIXTURES[1][0], preset.max_pixels)],
                             max_tokens=2, temperature=0.0, **preset.kwargs):
        pass
    results = []
    for image_name, reference_name in FIXTURES:
        image_path = EVALUATION / image_name
        reference = (EVALUATION / reference_name).read_text()
        lines_path = image_path.with_suffix(".lines.json")
        lines = json.loads(lines_path.read_text()) if lines_path.exists() else []
        mx.reset_peak_memory()
        mx.clear_cache()
        started = time.perf_counter()
        image = prepared_image(image_path, preset.max_pixels)
        prompt = apply_chat_template(processor, model.config, preset.prompt, num_images=1)
        text, first, last = "", None, None
        extra = {"logits_processors": [no_repeat_ngram()]} if preset.no_repeat_ngram else {}
        for result in stream_generate(model, processor, prompt, image=[image], max_tokens=max_tokens,
                                      temperature=0.0, **preset.kwargs, **extra):
            if first is None:
                first = time.perf_counter()
            text += result.text
            last = result
        total = time.perf_counter() - started
        plain, boxes = PARSERS[preset.format](text, Image.open(image_path).size)
        plain = strip_markup(strip_fences(plain)) if preset.format == "markdown" else plain
        row = {
            "model": name, "image": image_name,
            "promptTokens": last.prompt_tokens, "generatedTokens": last.generation_tokens,
            "timeToFirstToken": round(first - started, 3), "decodeTokensPerSecond": round(last.generation_tps, 1),
            "totalSeconds": round(total, 2), "peakMemoryMiB": int(mx.get_peak_memory() / 2**20),
            "hitLimit": last.generation_tokens >= max_tokens,
            "characterErrorRate": round(character_error_rate(plain, reference), 3) if preset.format != "mineru" else None,
            "boxes": box_metrics(boxes, lines), "loadSeconds": round(load_seconds, 2),
        }
        results.append(row)
        stem = image_path.stem + "-" + name
        (out / (stem + ".txt")).write_text(text)
        print(json.dumps(row), flush=True)
    del model, processor
    mx.clear_cache()
    return results


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--models", nargs="+", default=list(PRESETS), choices=list(PRESETS))
    parser.add_argument("--max-tokens", type=int, default=4096)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    report = args.out / "report.jsonl"
    for name in args.models:
        with report.open("a") as handle:
            try:
                for row in run(name, PRESETS[name], args.max_tokens, args.out):
                    handle.write(json.dumps(row) + "\n")
            except Exception:
                traceback.print_exc()
                handle.write(json.dumps({"model": name, "error": traceback.format_exc(limit=1)}) + "\n")


if __name__ == "__main__":
    main()
