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

    func testGPUNoRepeatBansMatchReferenceRule() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal GPU required") }
        let rule = NoRepeatNGram(size: 4, window: 12)
        var generator = SystemRandomNumberGenerator()
        for trial in 0..<200 {
            // A small alphabet makes repeated n-grams common.
            let length = Int.random(in: 0...30, using: &generator)
            let tokens = (0..<length).map { _ in Int.random(in: 0..<5, using: &generator) }
            var bans = NoRepeatNGramBans(rule)
            for token in tokens { bans.append(MLXArray([Int32(token)])) }
            let output = bans.apply(to: MLXArray.zeros([1, 8]))
            eval(output)
            let banned = Set((0..<8).filter { output[0, $0].item(Float.self) == -Float.infinity })
            let expected = Set(rule.bannedTokens(after: Array(tokens.suffix(rule.window))))
            XCTAssertEqual(banned, expected, "trial \(trial), history \(tokens)")
        }
    }

    func testResumablePrefixKeepsWholeLines() {
        XCTAssertEqual(FirebirdRuntime.resumablePrefix("# Title\n\nFirst par"), "# Title\n\n")
        XCTAssertEqual(FirebirdRuntime.resumablePrefix("no line break yet"), "")
    }

    func testSeededNoRepeatBansMatchAppendedHistory() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal GPU required") }
        let rule = NoRepeatNGram(size: 3, window: 8)
        let tokens: [Int32] = [1, 2, 3, 4, 1, 2, 5, 6, 7, 1, 2]
        var appended = NoRepeatNGramBans(rule)
        for token in tokens { appended.append(MLXArray([token])) }
        var seeded = NoRepeatNGramBans(rule)
        seeded.seed(MLXArray(tokens), count: tokens.count)
        let expected = appended.apply(to: MLXArray.zeros([1, 8]))
        let output = seeded.apply(to: MLXArray.zeros([1, 8]))
        eval(expected, output)
        XCTAssertEqual(output.asArray(Float.self), expected.asArray(Float.self))
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
/// `work/Evaluation/config.json`. Each variant runs every sample, so prompt,
/// decoding, resolution tier and attention kernel are compared on identical input:
///
///     {"modelPath": "...", "outputPath": "...",
///      "variants": [{"name": "baseline", "attention": "mlx", "prompt": "recipe",
///                    "decoding": "recipe", "tierCeiling": "extended"}],
///      "samples": [{"image": "page1.jpg", "reference": "page1.md"}]}
///
/// `prompt` is "recipe" or literal prompt text; `decoding` is "recipe" or
/// "greedy". Sample paths are relative to the config file; `reference` is optional.
extension ReconstructionTests {
    private struct EvaluationConfig: Decodable {
        struct Sample: Decodable { let image: String; let reference: String? }
        struct Variant: Decodable {
            let name: String
            let attention: String?
            let prompt: String?
            let decoding: String?
            let tierCeiling: String?
        }
        let modelPath: String
        let outputPath: String
        let maxOutputTokens: Int?
        let variants: [Variant]
        let samples: [Sample]
    }

    private struct SampleReport: Encodable {
        let image: String
        let variant: String
        let completed: Bool
        let failure: String?
        let characterErrorRate: Double?
        let metrics: FirebirdGenerationMetrics?
    }

    private func recipe(for variant: EvaluationConfig.Variant) throws -> FirebirdRecipe {
        let base = FirebirdRecipe.academicTranscription
        let prompt = variant.prompt.map { $0 == "recipe" ? base.prompt : $0 } ?? base.prompt
        let attempts: [FirebirdDecoding]
        switch variant.decoding ?? "recipe" {
        case "recipe": attempts = base.attempts
        case "greedy": attempts = [.greedy]
        case let other: throw XCTSkip("Unknown decoding \(other)")
        }
        return FirebirdRecipe(version: base.version + "-" + variant.name, prompt: prompt, attempts: attempts)
    }

    private func evaluationConfig() throws -> (EvaluationConfig, base: URL) {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal GPU required") }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let configURL = repository.appendingPathComponent("work/Evaluation/config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw XCTSkip("Optional local evaluation not configured")
        }
        let config = try JSONDecoder().decode(EvaluationConfig.self, from: Data(contentsOf: configURL))
        return (config, configURL.deletingLastPathComponent())
    }

    /// Interrupts every evaluation sample halfway (at a line break), resumes it,
    /// and expects the uninterrupted greedy transcription back. Uses the
    /// evaluation config's model and samples.
    func testResumeMatchesUninterruptedGeneration() async throws {
        let (config, base) = try evaluationConfig()
        let runtime = FirebirdRuntime()
        try await runtime.load(directory: URL(fileURLWithPath: config.modelPath))
        for sample in config.samples {
            let image = try Data(contentsOf: base.appendingPathComponent(sample.image))
            let full = try await runtime.reconstruct(imageData: image).markdown
            let half = String(full.prefix(full.count / 2))
            let partial = FirebirdRuntime.resumablePrefix(half)
            XCTAssertFalse(partial.isEmpty, "\(sample.image): no line break in the first half")
            let resumed = try await runtime.reconstruct(imageData: image, resumingFrom: half)
            XCTAssertTrue(resumed.markdown.hasPrefix(partial.trimmingCharacters(in: .whitespacesAndNewlines)))
            let rate = TranscriptionMetrics.characterErrorRate(prediction: resumed.markdown, reference: full)
            print("resume \(sample.image): resumed after \(partial.count) of \(full.count) characters, "
                + "\(resumed.metrics.promptTokens) prompt tokens, CER vs uninterrupted \(rate)")
            XCTAssertEqual(resumed.markdown, full, "\(sample.image): resumed output differs")
        }
    }

    func testLocalEvaluation() async throws {
        let (config, base) = try evaluationConfig()
        let destination = URL(fileURLWithPath: config.outputPath)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        var reports: [SampleReport] = []
        var loaded: (attention: FirebirdDecodeAttention, tier: FirebirdDeviceBudget.Tier, runtime: FirebirdRuntime)?
        for variant in config.variants {
            let attention = try XCTUnwrap(FirebirdDecodeAttention(rawValue: variant.attention ?? "mlx"),
                                          "Unknown attention \(variant.attention ?? "")")
            let tier = try XCTUnwrap(FirebirdDeviceBudget.Tier(rawValue: variant.tierCeiling ?? "extended"),
                                     "Unknown tier \(variant.tierCeiling ?? "")")
            let recipe = try recipe(for: variant)
            // Reload only when the attention kernel or resolution tier changes.
            if loaded?.attention != attention || loaded?.tier != tier {
                loaded = nil
                let runtime = FirebirdRuntime()
                try await runtime.load(directory: URL(fileURLWithPath: config.modelPath),
                    options: FirebirdRuntimeOptions(decodeAttention: attention, tierCeiling: tier,
                                                    maxOutputTokens: config.maxOutputTokens))
                loaded = (attention, tier, runtime)
            }
            let runtime = try XCTUnwrap(loaded?.runtime)
            for sample in config.samples {
                let imageURL = base.appendingPathComponent(sample.image)
                let stem = imageURL.deletingPathExtension().lastPathComponent + "-" + variant.name
                let reference = try sample.reference.map {
                    try String(contentsOf: base.appendingPathComponent($0), encoding: .utf8)
                }
                var output = ""
                var report: SampleReport
                do {
                    let result = try await runtime.reconstruct(imageData: Data(contentsOf: imageURL), recipe: recipe)
                    output = result.markdown
                    report = SampleReport(image: sample.image, variant: variant.name, completed: true, failure: nil,
                        characterErrorRate: reference.map { TranscriptionMetrics.characterErrorRate(prediction: output, reference: $0) },
                        metrics: result.metrics)
                } catch FirebirdRuntimeError.incomplete(let reason, let partial) {
                    output = partial
                    report = SampleReport(image: sample.image, variant: variant.name, completed: false,
                        failure: reason.rawValue, characterErrorRate: nil, metrics: nil)
                } catch {
                    report = SampleReport(image: sample.image, variant: variant.name, completed: false,
                        failure: "\(error)", characterErrorRate: nil, metrics: nil)
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
