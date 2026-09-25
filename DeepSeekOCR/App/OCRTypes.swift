import Foundation

enum OCRMode: String, CaseIterable, Identifiable {
    case document = "Markdown + LaTeX"
    case plainText = "Plain text"

    var id: Self { self }

    var prompt: String {
        switch self {
        case .document:
            "<|grounding|>Convert the document to markdown."
        case .plainText:
            "Free OCR."
        }
    }
}

enum OCRPerformanceMode: String, CaseIterable, Identifiable, Sendable {
    case accurate = "Accurate"
    case fast = "Fast"

    var id: Self { self }

    static var recommended: Self {
        Int(dsocr_recommended_vision_mode()) == DSOCR_VISION_MODE_FAST ? .fast : .accurate
    }

    var nativeValue: Int32 {
        switch self {
        case .accurate: Int32(DSOCR_VISION_MODE_ACCURATE)
        case .fast: Int32(DSOCR_VISION_MODE_FAST)
        }
    }

    var explanation: String {
        switch self {
        case .accurate:
            "Detail crops preserve small text and exact formulas. Recommended on iPhone."
        case .fast:
            "One 1024px overview is much faster, with less detail. Recommended on M-series iPad Pro."
        }
    }
}

struct OCRMetrics: Sendable {
    let modelLoadSeconds: Double
    let encodeSeconds: Double
    let generationSeconds: Double
    let inputTokens: Int
    let outputTokens: Int
    let isTruncated: Bool
    let fastVisionUsed: Bool

    var tokensPerSecond: Double {
        generationSeconds > 0 ? Double(outputTokens) / generationSeconds : 0
    }

    var summary: String {
        let prefill = encodeSeconds.formatted(.number.precision(.fractionLength(1)))
        let speed = tokensPerSecond.formatted(.number.precision(.fractionLength(1)))
        let truncation = isTruncated ? "  ·  token limit reached" : ""
        let vision = fastVisionUsed ? "Fast overview" : "Accurate details"
        return "\(vision) \(prefill)s  ·  \(outputTokens) tokens  ·  \(speed) tok/s\(truncation)"
    }
}

struct OCRResult: Sendable {
    let text: String
    let metrics: OCRMetrics
}

enum OCRError: LocalizedError {
    case missingModels
    case invalidImage
    case loadFailed(String)
    case inferenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingModels:
            "The bundled DeepSeek OCR model files are missing. Run scripts/bootstrap.sh before building."
        case .invalidImage:
            "The selected item is not a readable image."
        case .loadFailed(let message), .inferenceFailed(let message):
            message
        }
    }
}
