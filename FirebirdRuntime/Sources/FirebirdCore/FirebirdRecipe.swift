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

/// DeepSeek-OCR's reference no-repeat rule: a token is banned when it would
/// repeat an n-gram that already occurs in the recent generated window. Unlike
/// a penalty, it leaves short legitimate repetition (braces, matrix cells,
/// table rules) untouched and only blocks long verbatim cycles.
public struct NoRepeatNGram: Codable, Equatable, Sendable {
    public let size: Int
    public let window: Int

    public init(size: Int, window: Int) {
        precondition(size >= 2 && window >= size)
        self.size = size; self.window = window
    }

    public static let reference = NoRepeatNGram(size: 20, window: 1024)

    /// Tokens that would complete an n-gram already present in `history`,
    /// searching only the last `window` generated tokens.
    public func bannedTokens(after history: [Int]) -> [Int] {
        guard history.count >= size else { return [] }
        let prefixStart = history.count - (size - 1)
        let searchStart = max(0, history.count - window)
        let searchEnd = history.count - size + 1
        guard searchStart < searchEnd else { return [] }
        var banned: [Int] = []
        for start in searchStart..<searchEnd
        where history[start..<(start + size - 1)].elementsEqual(history[prefixStart...]) {
            banned.append(history[start + size - 1])
        }
        return banned
    }
}

/// One decoding attempt. Temperature 0 selects greedy (arg-max) decoding.
public struct FirebirdDecoding: Codable, Equatable, Sendable {
    public let temperature: Float
    public let topP: Float
    public let topK: Int
    public let penalty: FirebirdPenalty?
    public let noRepeatNGram: NoRepeatNGram?

    public init(temperature: Float = 0, topP: Float = 1, topK: Int = 0,
                penalty: FirebirdPenalty? = nil, noRepeatNGram: NoRepeatNGram? = nil) {
        self.temperature = temperature; self.topP = topP; self.topK = topK
        self.penalty = penalty; self.noRepeatNGram = noRepeatNGram
    }

    public static let greedy = FirebirdDecoding()
}

/// Everything besides the weights that determines a page transcription.
/// Changing any field must change `version`, which invalidates checkpoints.
public struct FirebirdRecipe: Codable, Equatable, Sendable {
    /// What the model writes: a Markdown page, or text elements with locations
    /// (`FirebirdSpotting`).
    public enum Output: String, Codable, Sendable { case markdown, spotting }

    public let version: String
    public let prompt: String
    /// Tried in order. A later attempt runs only after a repetition loop.
    public let attempts: [FirebirdDecoding]
    public let output: Output

    public init(version: String, prompt: String, attempts: [FirebirdDecoding], output: Output = .markdown) {
        precondition(!attempts.isEmpty)
        self.version = version; self.prompt = prompt; self.attempts = attempts; self.output = output
    }

    /// `qwenvl markdown` is Qwen3-VL's trained document-parsing prompt. On the
    /// DeepSeekOCR math fixture (M4, Release) it cut character error rate from
    /// 0.45 to 0.07 versus a long instruction prompt, which made the model emit
    /// a whole LaTeX document instead of Markdown. Decoding is greedy with the
    /// reference no-repeat rule; the fallback adds a mild generated-only
    /// repetition penalty for loops the rule cannot see.
    public static let academicTranscription = FirebirdRecipe(
        version: "recipe-4",
        prompt: "qwenvl markdown",
        attempts: [
            FirebirdDecoding(noRepeatNGram: .reference),
            FirebirdDecoding(penalty: FirebirdPenalty(kind: .repetition, value: 1.1, window: 64),
                             noRepeatNGram: .reference)
        ])
}

extension FirebirdRecipe {
    /// PaddleOCR-VL-1.5's trained spotting task: every text line with its
    /// quadrilateral. Without the no-repeat rule it looped on the screenshot
    /// fixture's checkbox list until the 4,096-token limit (mlx-vlm, M4); with
    /// it, character error rate was 0.081 there and 0.033 on handwriting. There
    /// is no penalty fallback: a repetition penalty also pushes location tokens
    /// away from values already used, and 1.05 did not stop the loop.
    public static let paddleSpotting = FirebirdRecipe(
        version: "paddle-spotting-1", prompt: "Spotting:",
        attempts: [FirebirdDecoding(noRepeatNGram: .reference)], output: .spotting)

    /// PaddleOCR-VL-1.5's plain text task, without locations.
    public static let paddleText = FirebirdRecipe(
        version: "paddle-text-1", prompt: "OCR:",
        attempts: [FirebirdDecoding(noRepeatNGram: .reference)])

    /// GLM-OCR's trained text task. On a dense paper page with charts it read
    /// only the text, where PaddleOCR-VL at the same resolution invented chart
    /// labels until the token limit (mlx-vlm, M4).
    public static let glmText = FirebirdRecipe(
        version: "glm-text-1", prompt: "Text Recognition:",
        attempts: [FirebirdDecoding(noRepeatNGram: .reference)])
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
