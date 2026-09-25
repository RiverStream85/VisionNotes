import FirebirdCore
import Foundation
import Metal
import OSLog
import FirebirdRuntime

enum FirebirdLocalFailure: Error {
    /// Generation stopped before a stop token; the partial text is a draft only.
    case incomplete(FirebirdIncompleteReason, partialMarkdown: String)
}

struct FirebirdCompletion: Sendable {
    let markdown: String
    let modelIdentifier: String
}

/// Real image-conditioned generation using the pinned Qwen3-VL checkpoint.
struct FirebirdLocalModel: Sendable {
    static let modelName = "Qwen3-VL-2B-Instruct (4-bit, local Firebird)"
    static let recipe = FirebirdRecipe.academicTranscription

    /// Derived from the bundled lock and the recipe, so a new revision or
    /// decoding change invalidates page checkpoints without editing call sites.
    static let identity: FirebirdModelIdentity = {
        let lock = try? FirebirdModelAssets.bundledLock()
        return FirebirdModelIdentity(repository: lock?.model ?? "unavailable",
            revision: lock?.revision ?? "unavailable", recipeVersion: recipe.version)
    }()

    static var modelIdentifier: String { identity.identifier }

    static func checkpointPath(pageIndex: Int) -> String { identity.checkpointPath(pageIndex: pageIndex) }

    func reconstruct(imageData: Data, progress: (@Sendable (String) async -> Void)? = nil) async throws -> FirebirdCompletion {
        #if targetEnvironment(simulator)
        // MLX requires Metal features the iOS simulator does not expose.
        throw MathNoteError.localInferenceUnavailable
        #else
        guard MTLCreateSystemDefaultDevice() != nil else { throw MathNoteError.localInferenceUnavailable }
        let logger = Logger(subsystem: "VisionNotes", category: "FirebirdSetup")
        let runtime = FirebirdRuntime.shared
        if !(await runtime.isLoaded()) {
            if let bundled = FirebirdModelAssets.bundledModelDirectory() {
                await progress?("Loading bundled local model")
                logger.notice("Loading model bundled with the app")
                try await Self.load(runtime, directory: bundled, logger: logger)
            } else {
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
                try await Self.load(runtime, directory: directory, logger: logger)
            }
        }
        do {
            let result = try await runtime.reconstruct(imageData: imageData, recipe: Self.recipe) { event in
                await progress?(Self.describe(event))
            }
            return FirebirdCompletion(markdown: Self.normalizeMarkdown(result.markdown),
                modelIdentifier: Self.modelIdentifier)
        } catch is CancellationError {
            throw CancellationError()
        } catch FirebirdRuntimeError.incomplete(let reason, let markdown) {
            throw FirebirdLocalFailure.incomplete(reason, partialMarkdown: markdown)
        } catch is FirebirdRuntimeError {
            throw MathNoteError.localInferenceUnavailable
        }
        #endif
    }

    private static func load(_ runtime: FirebirdRuntime, directory: URL, logger: Logger) async throws {
        do {
            try await runtime.load(directory: directory)
        } catch FirebirdRuntimeError.insufficientMemory(let available, let required) {
            logger.error("Not enough memory for local model: available MiB \(available / 1_048_576), required MiB \(required / 1_048_576)")
            throw MathNoteError.localInferenceUnavailable
        }
    }

    /// Status text only; page content never enters a status update.
    static func describe(_ event: FirebirdProgress) -> String {
        switch event {
        case .preparingImage: "Preparing page image"
        case .readingPage(let attempt): attempt == 1
            ? "Reading page · waiting for first text"
            : "Retrying page after repeated output · attempt \(attempt)"
        case .generating(let text, let elapsed, _): "Reconstructing · \(text.count) characters · \(Int(elapsed))s"
        case .finishing: "Checking completed reconstruction"
        }
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
