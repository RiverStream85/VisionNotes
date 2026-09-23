import Foundation
import Metal
import OSLog
import FirebirdRuntime

enum FirebirdLocalFailure: Error {
    case outputLimit(partialMarkdown: String)
}

struct FirebirdCompletion: Sendable {
    let markdown: String
    let modelIdentifier: String
}

/// Real image-conditioned generation using the pinned Qwen3-VL checkpoint.
struct FirebirdLocalModel: Sendable {
    static let modelName = "Qwen3-VL-2B-Instruct (4-bit, local Firebird)"

    static let modelIdentifier = FirebirdRuntime.modelIdentifier + "@9c4f5209e57b31f4b9dfba735de3fb983739c9cc/input-v2"

    func reconstruct(imageData: Data, progress: (@Sendable (String) async -> Void)? = nil) async throws -> FirebirdCompletion {
        #if targetEnvironment(simulator)
        // MLX requires Metal features the iOS simulator does not expose.
        throw MathNoteError.localInferenceUnavailable
        #else
        guard MTLCreateSystemDefaultDevice() != nil else { throw MathNoteError.localInferenceUnavailable }
        let logger = Logger(subsystem: "VisionNotes", category: "FirebirdSetup")
        let runtime = FirebirdRuntime.shared
        if !(await runtime.isLoaded()) {
            // Fetch public model assets only on first setup. No page is uploaded.
            // Crypto/authentication errors deliberately propagate unchanged.
            do {
                await progress?("Checking / downloading model · first setup")
                logger.notice("Checking or downloading encrypted model assets")
                try await FirebirdModelAssets.shared.ensureInstalled()
                logger.notice("Encrypted model assets ready")
            } catch is CancellationError { throw CancellationError() }
            catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                throw MathNoteError.localInferenceUnavailable
            }
            await progress?("Decrypting local model")
            logger.notice("Decrypting model for loading")
            let directory = try await FirebirdModelAssets.shared.materialize()
            defer { try? FileManager.default.removeItem(at: directory) }
            logger.notice("Model decryption complete")
            await progress?("Loading local model")
            try await runtime.load(directory: directory)
        }
        do {
            let markdown = try await runtime.reconstruct(imageData: imageData, progress: progress)
            return FirebirdCompletion(markdown: Self.normalizeMarkdown(markdown),
                modelIdentifier: Self.modelIdentifier)
        } catch is CancellationError {
            throw CancellationError()
        } catch FirebirdRuntimeError.outputLimit(let markdown) {
            throw FirebirdLocalFailure.outputLimit(partialMarkdown: markdown)
        } catch is FirebirdRuntimeError {
            throw MathNoteError.localInferenceUnavailable
        }
        #endif
    }

    /// Some local generations wrap equations in a LaTeX code fence despite the
    /// prompt. Adapt only a complete outer fence; never rewrite mathematical tokens.
    static func normalizeMarkdown(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = trimmed.components(separatedBy: "\n")
        guard lines.count >= 3, lines.last == "```" else { return trimmed }
        let language = lines.removeFirst().lowercased()
        guard ["```", "```markdown", "```md", "```latex", "```tex"].contains(language) else { return trimmed }
        lines.removeLast()
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard language == "```latex" || language == "```tex" else { return body }
        for name in ["align*", "align", "aligned"] {
            let start = "\\begin{\(name)}", end = "\\end{\(name)}"
            if body.hasPrefix(start), body.hasSuffix(end) {
                let equations = body.dropFirst(start.count).dropLast(end.count)
                return "$$\n\\begin{aligned}\(equations)\\end{aligned}\n$$"
            }
        }
        return trimmed
    }

}
