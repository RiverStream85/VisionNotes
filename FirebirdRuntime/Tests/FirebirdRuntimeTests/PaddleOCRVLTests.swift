import XCTest
import CoreImage
import Metal
import FirebirdCore
import Hub
import MLX
import MLXLMCommon
@testable import FirebirdRuntime

final class PaddleOCRVLTests: XCTestCase {
    func testSmartResizeMatchesReference() {
        // Values from the reference `smart_resize` (factor 28, 112,896...1,003,520 pixels).
        XCTAssertEqual(PaddleOCRVLProcessor.targetSize(height: 2868, width: 1320, factor: 28,
                                                       minPixels: 112_896, maxPixels: 1_003_520).0, 1456)
        XCTAssertEqual(PaddleOCRVLProcessor.targetSize(height: 2868, width: 1320, factor: 28,
                                                       minPixels: 112_896, maxPixels: 1_003_520).1, 672)
        XCTAssertEqual(PaddleOCRVLProcessor.targetSize(height: 20, width: 400, factor: 28,
                                                       minPixels: 112_896, maxPixels: 1_003_520).0, 84)
    }

    func testRopePositionsMatchReference() {
        // Two text tokens, a 2×3 merged image, then two text tokens.
        let tokens = [7, 8] + Array(repeating: 99, count: 6) + [9, 10]
        let (positions, delta) = PaddleOCRVL.positions(tokens: tokens, imageTokenId: 99, grid: THW(1, 4, 6), mergeSize: 2)
        XCTAssertEqual(positions.asArray(Int32.self), [
            0, 1, 2, 2, 2, 2, 2, 2, 5, 6,
            0, 1, 2, 2, 2, 3, 3, 3, 5, 6,
            0, 1, 2, 3, 4, 2, 3, 4, 5, 6,
        ])
        XCTAssertEqual(delta, 7 - 10)
    }

    func testSpottingParsesElementsIntoVisionBoxes() {
        let output = "Title<|LOC_50|><|LOC_100|><|LOC_550|><|LOC_100|><|LOC_550|><|LOC_150|><|LOC_50|><|LOC_150|>\n"
            + "\\[\nx^2\n\\]<|LOC_40|><|LOC_200|><|LOC_300|><|LOC_210|><|LOC_300|><|LOC_260|><|LOC_40|><|LOC_250|>\nunfinish"
        let spotting = FirebirdSpotting(parsing: output)
        XCTAssertEqual(spotting.lines.map(\.text), ["Title", "\\[\nx^2\n\\]"])
        let box = spotting.lines[0].boundingBox
        XCTAssertEqual(box.minX, 0.05, accuracy: 1e-9)
        XCTAssertEqual(box.minY, 0.85, accuracy: 1e-9)
        XCTAssertEqual(box.width, 0.5, accuracy: 1e-9)
        XCTAssertEqual(box.height, 0.05, accuracy: 1e-9)
        XCTAssertEqual(spotting.markdown, "Title\n\\[\nx^2\n\\]")
    }

    /// Compares the port with tensors dumped from mlx-vlm 0.7.3 (with torch's
    /// bilinear position interpolation, as in the HF model) by the script in
    /// Evaluation/README.md. Configured by the git-ignored
    /// `work/Evaluation/paddle-reference.json`:
    ///
    ///     {"modelPath": "...", "references": [{"tensors": "screenshot.safetensors",
    ///       "image": "../../Evaluation/screenshot-ocr-test.png", "prompt": "Spotting:"}]}
    func testMatchesMLXVLMReference() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal GPU required") }
        struct Config: Decodable {
            struct Reference: Decodable { let tensors: String; let image: String; let prompt: String }
            let modelPath: String
            let references: [Reference]
        }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let configURL = repository.appendingPathComponent("work/Evaluation/paddle-reference.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw XCTSkip("PaddleOCR-VL reference comparison not configured")
        }
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: configURL))
        let base = configURL.deletingLastPathComponent()
        let directory = URL(fileURLWithPath: config.modelPath)
        let data = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        let modelConfig = try JSONDecoder().decode(PaddleOCRVLConfiguration.self, from: data)
        let model = PaddleOCRVL(modelConfig)
        try loadWeights(modelDirectory: directory, model: model,
                        perLayerQuantization: JSONDecoder().decode(BaseConfiguration.self, from: data).perLayerQuantization)
        let tokenizer = try await loadTokenizer(configuration: ModelConfiguration(directory: directory), hub: HubApi())
        let processor = PaddleOCRVLProcessor(
            try JSONDecoder().decode(PaddleOCRVLProcessorConfiguration.self,
                from: Data(contentsOf: directory.appendingPathComponent("preprocessor_config.json"))),
            tokenizer: tokenizer, imageTokenId: modelConfig.imageTokenId)

        for reference in config.references {
            let arrays = try loadArrays(url: base.appendingPathComponent(reference.tensors))
            let ids = try XCTUnwrap(arrays["input_ids"])
            let pixels = try XCTUnwrap(arrays["pixel_values"]).reshaped(-1, 3, 14, 14)
            let gridValues = try XCTUnwrap(arrays["image_grid_thw"]).asArray(Int32.self).map(Int.init)
            let grid = THW(gridValues[0], gridValues[1], gridValues[2])
            let name = reference.tensors

            // Prompt tokens and image preprocessing.
            let image = try XCTUnwrap(CIImage(contentsOf: base.appendingPathComponent(reference.image)))
            let prepared = try await processor.prepare(input: UserInput(chat: [.user(reference.prompt, images: [.ciImage(image)])]))
            XCTAssertEqual(prepared.text.tokens.asArray(Int32.self), ids.asArray(Int32.self), "\(name): prompt tokens")
            let preparedGrid = try XCTUnwrap(prepared.image?.frames?.first)
            XCTAssertEqual([preparedGrid.t, preparedGrid.h, preparedGrid.w], gridValues, "\(name): grid")
            if let preparedPixels = prepared.image?.pixels, preparedPixels.shape == pixels.shape {
                let difference = abs(preparedPixels - pixels)
                print("paddle \(name): CoreImage vs PIL pixels mean |diff| \(difference.mean().item(Float.self)), "
                    + "max \(difference.max().item(Float.self)) (range -1...1)")
            }

            // Vision encoder and projector on the reference pixels. A few tokens diverge in bf16
            // alone: mlx-vlm's float32 encoder against its own bf16 run has a min cosine of about
            // 0.5 on these fixtures, so only the mean is a meaningful bound.
            let features = model.visual(pixels, grid: grid).asType(.float32)
            let expected = try XCTUnwrap(arrays["features"])
            let cosine = (sum(features * expected, axis: -1)
                / (sqrt(sum(features * features, axis: -1)) * sqrt(sum(expected * expected, axis: -1))))
            let meanCosine = cosine.mean().item(Float.self)
            print("paddle \(name): features max |diff| \(abs(features - expected).max().item(Float.self)), "
                + "mean cosine \(meanCosine), min cosine \(cosine.min().item(Float.self))")
            XCTAssertGreaterThan(meanCosine, 0.99, "\(name): vision features")

            // First-token logits, then greedy continuation.
            let cache = model.newCache(parameters: nil)
            let input = LMInput(text: .init(tokens: ids, mask: ones(like: ids).asType(.int8)),
                                image: .init(pixels: pixels, frames: [grid]))
            guard case .logits(let output) = try model.prepare(input, cache: cache, windowSize: nil) else {
                return XCTFail("prepare must return logits")
            }
            var logits = output.logits[0, -1].asType(.float32)
            let expectedLogits = try XCTUnwrap(arrays["logits"])[0]
            let top = Array(argSort(-logits).asArray(Int32.self).prefix(5))
            let expectedTop = Array(argSort(-expectedLogits).asArray(Int32.self).prefix(5))
            print("paddle \(name): first-token logits max |diff| \(abs(logits - expectedLogits).max().item(Float.self)), "
                + "top-5 \(top) vs \(expectedTop)")
            XCTAssertEqual(top.first, expectedTop.first, "\(name): first token")

            let greedy = try XCTUnwrap(arrays["greedy"]).asArray(Int32.self)
            var tokens: [Int32] = []
            for _ in greedy {
                let token = argMax(logits).item(Int32.self)
                tokens.append(token)
                logits = model(MLXArray([token]).reshaped(1, 1), cache: cache)[0, -1].asType(.float32)
            }
            let agreement = zip(tokens, greedy).prefix { $0 == $1 }.count
            print("paddle \(name): greedy tokens agree for \(agreement) of \(greedy.count)")
            XCTAssertEqual(tokens, greedy, "\(name): greedy continuation")
        }
    }
}
