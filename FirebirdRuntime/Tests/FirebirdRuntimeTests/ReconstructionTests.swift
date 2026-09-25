import XCTest
import Metal
import CoreImage
import FirebirdCore
import MLXLMCommon
import MLX
@testable import FirebirdRuntime

final class ReconstructionTests: XCTestCase {
    func testReconstructionInputIncludesImageInProcessorAndChat() {
        let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        let input = FirebirdRuntime.makeInput(image: image, prompt: FirebirdRecipe.academicTranscription.prompt)
        XCTAssertEqual(input.images.count, 1, "The processor must receive the actual image")
        guard case .chat(let messages) = input.prompt else {
            return XCTFail("Reconstruction must use structured multimodal chat")
        }
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].images.count, 1, "The template must receive an image placeholder")
    }

    func testGeneratedTokenPenaltyIgnoresPrompt() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal GPU required") }
        var processor = GeneratedTokenPenalty(FirebirdPenalty(kind: .presence, value: 1.5, window: 64))
        processor.prompt(MLXArray([Int32(1), 2, 2], [1, 3]))
        let untouched = processor.process(logits: MLXArray.zeros([1, 8]))
        eval(untouched)
        XCTAssertEqual(untouched[0, 1].item(Float.self), 0, "Prompt tokens must not be penalized")
        processor.didSample(token: MLXArray(Int32(3)))
        let output = processor.process(logits: MLXArray.zeros([1, 8]))
        eval(output)
        XCTAssertEqual(output[0, 2].item(Float.self), 0)
        XCTAssertEqual(output[0, 3].item(Float.self), -1.5)
    }

    func testProcessorConfigurationCapsPixels() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = """
            {"image_mean": [0.5, 0.5, 0.5], "image_std": [0.5, 0.5, 0.5], "min_pixels": 3136,
             "max_pixels": 12845056, "merge_size": 2, "patch_size": 16, "temporal_patch_size": 2,
             "image_processor_type": "Qwen2VLImageProcessorFast"}
            """
        try Data(json.utf8).write(to: directory.appendingPathComponent("preprocessor_config.json"))
        let config = try FirebirdRuntime.processorConfiguration(in: directory, maxPixels: 786_432)
        XCTAssertEqual(config.maxPixels, 786_432)
        XCTAssertEqual(config.minPixels, 3136)
    }

    /// Opt-in real-checkpoint integration test. Use a handwritten sample and a
    /// known formula fragment; no deterministic fixture replaces the model.
    func testColdLoadAndReconstructRealImage() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let modelPath = env["FIREBIRD_MODEL_DIR"],
              let imagePath = env["FIREBIRD_TEST_IMAGE"],
              let expected = env["FIREBIRD_EXPECTED_LATEX"], !expected.isEmpty else {
            throw XCTSkip("Set model directory, handwritten image, and expected LaTeX fragment")
        }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal GPU required") }
        let runtime = FirebirdRuntime()
        try await runtime.load(directory: URL(fileURLWithPath: modelPath))
        let output = try await runtime.reconstruct(imageData: Data(contentsOf: URL(fileURLWithPath: imagePath)))
        XCTAssertTrue(output.markdown.contains(expected), "Known formula was not reconstructed")
    }
}

/// Optional local evaluation, configured by the git-ignored
/// `work/Evaluation/config.json`. Every sample runs under each attention mode,
/// so accuracy and speed of the fused kernel are compared on identical input:
///
///     {"modelPath": "...", "outputPath": "...", "tierCeiling": "extended",
///      "attention": ["mlx", "fusedExperimental"],
///      "samples": [{"image": "page1.jpg", "reference": "page1.md"}]}
///
/// Sample paths are relative to the config file. `reference` is optional.
extension ReconstructionTests {
    private struct EvaluationConfig: Decodable {
        struct Sample: Decodable { let image: String; let reference: String? }
        let modelPath: String
        let outputPath: String
        let tierCeiling: String?
        let attention: [String]?
        let maxOutputTokens: Int?
        let samples: [Sample]
    }

    private struct SampleReport: Encodable {
        let image: String
        let attention: String
        let completed: Bool
        let failure: String?
        let characterErrorRate: Double?
        let metrics: FirebirdGenerationMetrics?
    }

    func testLocalEvaluation() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal GPU required") }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let configURL = repository.appendingPathComponent("work/Evaluation/config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw XCTSkip("Optional local evaluation not configured")
        }
        let config = try JSONDecoder().decode(EvaluationConfig.self, from: Data(contentsOf: configURL))
        let base = configURL.deletingLastPathComponent()
        let destination = URL(fileURLWithPath: config.outputPath)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let modes = try (config.attention ?? ["mlx"]).map {
            try XCTUnwrap(FirebirdDecodeAttention(rawValue: $0), "Unknown attention mode \($0)")
        }
        let ceiling = try config.tierCeiling.map {
            try XCTUnwrap(FirebirdDeviceBudget.Tier(rawValue: $0), "Unknown tier \($0)")
        } ?? FirebirdDeviceBudget.defaultCeiling

        var reports: [SampleReport] = []
        for mode in modes {
            let runtime = FirebirdRuntime()
            try await runtime.load(directory: URL(fileURLWithPath: config.modelPath),
                options: FirebirdRuntimeOptions(decodeAttention: mode, tierCeiling: ceiling,
                                                maxOutputTokens: config.maxOutputTokens))
            for sample in config.samples {
                let imageURL = base.appendingPathComponent(sample.image)
                let stem = imageURL.deletingPathExtension().lastPathComponent + "-" + mode.rawValue
                let reference = try sample.reference.map {
                    try String(contentsOf: base.appendingPathComponent($0), encoding: .utf8)
                }
                var output = ""
                var report: SampleReport
                do {
                    let result = try await runtime.reconstruct(imageData: Data(contentsOf: imageURL))
                    output = result.markdown
                    report = SampleReport(image: sample.image, attention: mode.rawValue, completed: true, failure: nil,
                        characterErrorRate: reference.map { TranscriptionMetrics.characterErrorRate(prediction: output, reference: $0) },
                        metrics: result.metrics)
                } catch FirebirdRuntimeError.incomplete(let reason, let partial) {
                    output = partial
                    report = SampleReport(image: sample.image, attention: mode.rawValue, completed: false,
                        failure: reason.rawValue, characterErrorRate: nil, metrics: nil)
                }
                try output.write(to: destination.appendingPathComponent(stem + ".md"), atomically: true, encoding: .utf8)
                reports.append(report)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(reports).write(to: destination.appendingPathComponent("report.json"))
        XCTAssertTrue(reports.allSatisfy(\.completed), "Some samples did not reach a stop token; see report.json")
    }
}
