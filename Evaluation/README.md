# OCR evaluation

Fixtures and two harnesses for measuring on-device OCR speed and quality:
the Swift harness runs the app's Firebird runtime exactly as shipped, and
`bench_vlm.py` compares other document-OCR models through Python mlx-vlm.

## Fixtures

| Image | Reference | Boxes | Content |
| --- | --- | --- | --- |
| `math-ocr-test.png` | `math-ocr-reference.md` | none | typeset math page (from `math-ocr-test.tex`) |
| `screenshot-ocr-test.png` | `screenshot-ocr-expected.md` | `screenshot-ocr-test.lines.json` | 1320×2868 notes-app screenshot |
| `handwriting-ocr-test.jpg` | `handwriting-ocr-expected.md` | `handwriting-ocr-test.lines.json` | synthetic handwritten-style physics notes |

`math-ocr-reference.md` is `math-ocr-expected.md` without its closing
verification note, which is not on the page. `verify-math-output.py` checks a
transcription against the expected formulas.

Regenerate the rendered fixtures and boxes with:

    swift Evaluation/make-screenshot-fixture.swift
    swift Evaluation/make-handwriting-fixture.swift   # also writes its .lines.json
    swiftc -O Evaluation/vision-lines.swift -o /tmp/vision-lines
    /tmp/vision-lines Evaluation/screenshot-ocr-test.png

Screenshot boxes come from Apple Vision's fast recognizer (the accurate one
fails with an e5rt error outside a GUI session); handwriting boxes are exact.
The math page has no boxes because Vision fragments formulas.

## Swift harness (Firebird)

`FirebirdRuntime/Tests/FirebirdRuntimeTests/ReconstructionTests.swift` reads
the git-ignored `work/Evaluation/config.json` (format in the test's doc
comment); paths are relative to that file:

    {"modelPath": "/path/to/FirebirdModel", "outputPath": "/tmp/eval",
     "variants": [{"name": "high", "tierCeiling": "high"},
                  {"name": "standard", "tierCeiling": "standard"}],
     "samples": [{"image": "../../Evaluation/screenshot-ocr-test.png",
                  "reference": "../../Evaluation/screenshot-ocr-expected.md"}]}

Run it in Release; Debug compiles the MLX core at `-O0` and decodes about
4.7× slower:

    cd FirebirdRuntime
    xcodebuild test -scheme FirebirdRuntime -configuration Release ENABLE_TESTABILITY=YES \
      -destination 'platform=macOS,arch=arm64' \
      -only-testing:FirebirdRuntimeTests/ReconstructionTests/testLocalEvaluation

`outputPath` receives each transcription and `report.json` with, per variant
and sample, the prompt and output tokens, time to first token, decode tokens/s,
total time, peak memory and CER. `testResumeMatchesUninterruptedGeneration`
uses the same config: it transcribes each sample, resumes from the first half
of the output, and requires the resumed page to match. For spotting it requires
the same lines and allows each box corner to move by 0.005: coordinate tokens
are near ties, and batched prefill rounds differently from one-token decode.

The same harness runs PaddleOCR-VL-1.5. Point `modelPath` at its checkpoint
(`Tools/download_firebird_model.py --model paddleocr-vl`), set `"recipe":
"paddle-spotting"` (or `"paddle-text"`, top level or per variant) and give
samples their `"lines"` file; spotting runs then also write the raw output
(`.txt`) and report the box metrics described below.

`PaddleOCRVLTests.testMatchesMLXVLMReference` checks the Swift port against
mlx-vlm tensors listed in `work/Evaluation/paddle-reference.json`:

    {"modelPath": "/path/to/PaddleOCRVLModel",
     "references": [{"tensors": "screenshot-spot.safetensors",
                     "image": "../../Evaluation/screenshot-ocr-test.png", "prompt": "Spotting:"}]}

Write the tensors with `Evaluation/paddle_reference.py IMAGE PROMPT OUT
[MAX_TOKENS]` (mlx-vlm 0.7.3). The test compares prompt ids, grid, the
processor's pixels, vision features (mean cosine; single tokens differ by bf16
rounding alone), first-token logits and the greedy continuation.

xctest cannot read files on an external volume without Full Disk Access
("Operation not permitted"); copy the checkout and model to the internal disk
first if they live elsewhere.

## Python benchmark (other models)

    uv venv -p 3.12 .venv && uv pip install -p .venv/bin/python mlx-vlm==0.7.3 torch torchvision addict matplotlib einops easydict
    # torch and the rest are for DeepSeek-OCR's processor
    HF_HOME=/path/with/space .venv/bin/python Evaluation/bench_vlm.py \
      --models firebird deepseek-ocr paddleocr-vl-spot-nr --out /tmp/bench

Each preset names a checkpoint, prompt and output format; `--models` without
arguments runs them all. A warm-up generation precedes the measured ones, so
times exclude compilation but include image preprocessing. Output goes to
`<out>/report.jsonl` and one text file per model and fixture. Weights are
downloaded on first use (0.7–5 GB per model).

Metrics:

- `timeToFirstToken`: image processing, vision encoding and prefill.
- `decodeTokensPerSecond`, `generatedTokens`, `totalSeconds`, `peakMemoryMiB`
  (MLX peak), `hitLimit` (ran into `--max-tokens`, usually a loop).
- `characterErrorRate`: edit distance over reference length after the Swift
  harness's normalization, with fences, markup and box annotations stripped.
- `boxes`, for models that emit them: `lineRecall` (reference lines whose
  center lies in a predicted box), `boxPrecision` (predicted boxes containing a
  reference line center) and `meanIoU` (each such box against the union of the
  lines it contains). Block-level boxes therefore score well without matching
  line granularity; they are rough checks, not detection mAP.

Mac numbers do not transfer directly to an iPhone. For scale, an earlier
llama.cpp run of a Qwen3-VL-2B fine-tune on an iPhone 15 Pro decoded about
22 tokens/s with a 12.8 s image encode, against about 70 tokens/s and a 2.8 s
time to first token for Firebird on an M4 Mac mini.
