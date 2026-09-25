import Foundation

/// A logit penalty that sees only generated tokens. Prompt tokens (the
/// instruction text and image placeholders) are never penalized, because
/// LaTeX transcription legitimately repeats `\`, `{`, `}`, `_`, `^` and `$`.
public struct FirebirdPenalty: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case repetition, presence }
    public let kind: Kind
    public let value: Float
    public let window: Int

    public init(kind: Kind, value: Float, window: Int) {
        self.kind = kind; self.value = value; self.window = window
    }
}

/// One decoding attempt. Temperature 0 selects greedy (arg-max) decoding.
public struct FirebirdDecoding: Codable, Equatable, Sendable {
    public let temperature: Float
    public let topP: Float
    public let topK: Int
    public let penalty: FirebirdPenalty?

    public init(temperature: Float = 0, topP: Float = 1, topK: Int = 0, penalty: FirebirdPenalty? = nil) {
        self.temperature = temperature; self.topP = topP; self.topK = topK; self.penalty = penalty
    }

    public static let greedy = FirebirdDecoding()
}

/// Everything besides the weights that determines a page transcription.
/// Changing any field must change `version`, which invalidates checkpoints.
public struct FirebirdRecipe: Codable, Equatable, Sendable {
    public let version: String
    public let prompt: String
    /// Tried in order. A later attempt runs only after a repetition loop.
    public let attempts: [FirebirdDecoding]

    public init(version: String, prompt: String, attempts: [FirebirdDecoding]) {
        precondition(!attempts.isEmpty)
        self.version = version; self.prompt = prompt; self.attempts = attempts
    }

    /// Greedy first, so identical input gives identical output and can be
    /// regression-tested. The fallback breaks a degenerate loop with a mild,
    /// generated-only repetition penalty instead of random sampling.
    public static let academicTranscription = FirebirdRecipe(
        version: "recipe-3",
        prompt: """
            Transcribe this handwritten academic page faithfully into Markdown with LaTeX mathematics.
            Preserve the reading order, headings, all formulas, subscripts, superscripts and matrices.
            Use $...$ for inline math and $$...$$ for display math. Do not solve, summarize, or invent text.
            Mark genuinely unreadable content [unclear: description]. Return only the document, without a code fence.
            """,
        attempts: [
            .greedy,
            FirebirdDecoding(penalty: FirebirdPenalty(kind: .repetition, value: 1.1, window: 64))
        ])
}

/// Identity of a pinned model plus the recipe applied to it. Page checkpoints
/// are keyed by this value, so no string is duplicated across call sites.
public struct FirebirdModelIdentity: Equatable, Sendable {
    public let repository: String
    public let revision: String
    public let recipeVersion: String

    public init(repository: String, revision: String, recipeVersion: String) {
        self.repository = repository; self.revision = revision; self.recipeVersion = recipeVersion
    }

    public var identifier: String { "\(repository)@\(revision)/\(recipeVersion)" }

    /// A filesystem-safe, stable checkpoint prefix derived from the identifier.
    public var checkpointPrefix: String {
        let model = repository.split(separator: "/").last.map(String.init) ?? repository
        let slug = model.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return "firebird-\(String(slug))-\(revision.prefix(8))-\(recipeVersion)"
    }

    public func checkpointPath(pageIndex: Int) -> String {
        String(format: "%@-page-%03d.json", checkpointPrefix, pageIndex + 1)
    }
}
