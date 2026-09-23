import XCTest
import Metal
import CoreImage
import MLXLMCommon
import MLX
@testable import FirebirdRuntime

final class ReconstructionTests: XCTestCase {
    func testReconstructionInputIncludesImageInProcessorAndChat() {
        let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        let input = FirebirdRuntime.makeInput(image: image)
        XCTAssertEqual(input.images.count, 1, "The processor must receive the actual image")
        guard case .chat(let messages) = input.prompt else {
            return XCTFail("Reconstruction must use structured multimodal chat")
        }
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].images.count, 1, "The template must receive an image placeholder")
    }

    func testPresencePenaltyAcceptsBatchedImagePrompt() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal GPU required") }
        var processor = FirebirdPresencePenalty()
        processor.prompt(MLXArray([Int32(1), 2, 2], [1, 3]))
        processor.didSample(token: MLXArray(Int32(3)))
        let output = processor.process(logits: MLXArray.zeros([1, 8]))
        eval(output)
        XCTAssertEqual(output[0, 0].item(Float.self), 0)
        XCTAssertEqual(output[0, 2].item(Float.self), -1.5)
        XCTAssertEqual(output[0, 3].item(Float.self), -1.5)
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
        XCTAssertTrue(output.contains(expected), "Known formula was not reconstructed")
    }
}

// Optional local regression configuration is ignored by git and never bundled.
// Both paths use the same image/checkpoint/prompt. Only attention differs.
extension ReconstructionTests {
    func testLocalHandwritingAgainstReferenceAttention() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal GPU required") }
        struct Config: Decodable { let modelPath: String; let imagePath: String; let outputPath: String }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let configURL = repository.appendingPathComponent("work/Regression/config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw XCTSkip("Optional local handwriting regression not configured")
        }
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: configURL))
        let destination = URL(fileURLWithPath: config.outputPath)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let image = try Data(contentsOf: URL(fileURLWithPath: config.imagePath))
        for reference in [true, false] {
            let name = reference ? "reference" : "fused"
            MLXRandom.seed(42)
            let started = Date()
            var completed = false
            var output = ""
            do {
                output = try await FirebirdAttentionDiagnostics.$useReference.withValue(reference) {
                    try await FirebirdAttentionDiagnostics.$capturePartial.withValue({ partial in
                        try? partial.write(to: destination.appendingPathComponent(name + "-live.md"),
                            atomically: true, encoding: .utf8)
                    }) {
                        let runtime = FirebirdRuntime()
                        try await runtime.load(directory: URL(fileURLWithPath: config.modelPath))
                        return try await FirebirdAttentionDiagnostics.$outputLimit.withValue(768) {
                            try await runtime.reconstruct(imageData: image)
                        }
                    }
                }
                completed = true
            } catch FirebirdRuntimeError.outputLimit(let partial) {
                output = partial
            }
            try output.write(to: destination.appendingPathComponent(name + ".md"), atomically: true, encoding: .utf8)
            let status = "completed=\(completed) characters=\(output.count) seconds=\(Date().timeIntervalSince(started)) mlxPeakMiB=\(Memory.peakMemory / 1_048_576)"
            try status.write(to: destination.appendingPathComponent(name + "-status.txt"), atomically: true, encoding: .utf8)
            XCTAssertTrue(completed, "\(name) did not reach a stop token")
            XCTAssertLessThan(output.count, 3000, "A few formulas should not produce thousands of extra characters")
            XCTAssertTrue(output.contains("="), "No equation was produced")
        }
    }
}
