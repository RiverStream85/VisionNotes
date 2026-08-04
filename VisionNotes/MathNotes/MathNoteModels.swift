import Foundation

enum MathNoteStage: String, Codable, CaseIterable, Sendable {
    case draft
    case preparing
    case baseOCR
    case refining
    case rendering
    case complete
    case failed
    case cancelled

    var displayName: String {
        switch self {
        case .draft: "Draft"
        case .preparing: "Preparing pages"
        case .baseOCR: "Base OCR"
        case .refining: "Vision correction"
        case .rendering: "Building documents"
        case .complete: "Complete"
        case .failed: "Needs attention"
        case .cancelled: "Paused"
        }
    }

    var progress: Double {
        switch self {
        case .draft: 0
        case .preparing: 0.12
        case .baseOCR: 0.32
        case .refining: 0.62
        case .rendering: 0.86
        case .complete: 1
        case .failed, .cancelled: 0
        }
    }
}

struct MathNoteArtifactPaths: Codable, Equatable, Sendable {
    var markdown = "document.md"
    var latex = "document.tex"
    var pdf = "document.pdf"
    var html = "document.html"
    var facsimileLatex = "facsimile.tex"
    var facsimilePDF = "facsimile.pdf"
    var facsimileHTML = "facsimile.html"
    var archive = "artifacts.zip"
}

struct MathNotePageRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var index: Int
    var sourcePath: String
    var pixelWidth: Int
    var pixelHeight: Int

    init(
        id: UUID = UUID(),
        index: Int,
        sourcePath: String,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0
    ) {
        self.id = id
        self.index = index
        self.sourcePath = sourcePath
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

struct MathNoteJobManifest: Identifiable, Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = currentVersion
    let id: UUID
    var title: String
    var stage: MathNoteStage
    var createdAt: Date
    var updatedAt: Date
    var pages: [MathNotePageRecord]
    var uncertainCount: Int
    var artifacts: MathNoteArtifactPaths
    var failureMessage: String?
    var rendererDescription: String
    var stageProgress: Double?
    var stageDetail: String?

    var pageCount: Int { pages.count }
    var displayedProgress: Double { stageProgress ?? stage.progress }

    init(id: UUID = UUID(), title: String, pages: [MathNotePageRecord]) {
        self.id = id
        self.title = title
        stage = .draft
        createdAt = Date()
        updatedAt = createdAt
        self.pages = pages
        uncertainCount = 0
        artifacts = MathNoteArtifactPaths()
        failureMessage = nil
        rendererDescription = "On-device HTML + MathML rendered by WebKit"
        stageProgress = nil
        stageDetail = nil
    }
}

struct ProviderTokenUsage: Codable, Equatable, Sendable {
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
}

struct MathNoteCropTranscript: Codable, Equatable, Sendable {
    let index: Int
    let transcript: String
    let usage: ProviderTokenUsage?
}

struct MathNotePageRefinement: Codable, Equatable, Sendable {
    let pageIndex: Int
    let provider: String
    let model: String
    let overviewTranscript: String
    let overviewUsage: ProviderTokenUsage?
    let crops: [MathNoteCropTranscript]
    let mergeTranscript: String
    let mergeUsage: ProviderTokenUsage?
    let finalMarkdown: String
}

struct MathNoteRefinementRecord: Codable, Equatable, Sendable {
    let version: Int
    let provider: String
    let model: String
    let createdAt: Date
    let pages: [MathNotePageRefinement]

    init(pages: [MathNotePageRefinement]) {
        version = 1
        provider = "SiliconFlow"
        model = SiliconFlowVisionClient.model
        createdAt = Date()
        self.pages = pages
    }
}

struct ProviderKeys: Sendable, Equatable {
    let mistral: String
    let siliconFlow: String

    static func load(bundle: Bundle = .main) throws -> ProviderKeys {
        guard let url = bundle.url(forResource: "ProviderKeys", withExtension: "plist") else {
            throw MathNoteError.missingProviderKeys
        }
        let file: ProviderKeysFile
        do {
            file = try PropertyListDecoder().decode(
                ProviderKeysFile.self,
                from: Data(contentsOf: url)
            )
        } catch {
            throw MathNoteError.invalidProviderKeys
        }
        let mistral = file.mistral.trimmingCharacters(in: .whitespacesAndNewlines)
        let siliconFlow = file.siliconFlow.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mistral.isEmpty, !siliconFlow.isEmpty else {
            throw MathNoteError.emptyProviderKey
        }
        return ProviderKeys(mistral: mistral, siliconFlow: siliconFlow)
    }
}

private struct ProviderKeysFile: Decodable {
    let mistral: String
    let siliconFlow: String

    enum CodingKeys: String, CodingKey {
        case mistral = "MistralAPIKey"
        case siliconFlow = "SiliconFlowAPIKey"
    }
}

enum MathNoteError: LocalizedError, Equatable, Sendable {
    case missingProviderKeys
    case invalidProviderKeys
    case emptyProviderKey
    case invalidImage
    case emptyDraft
    case jobNotFound
    case malformedProviderResponse
    case providerRejected(status: Int)
    case providerUnavailable
    case visionRequestsIncomplete(completed: Int, total: Int)
    case refinementPageMismatch(expected: Int, actual: Int)
    case renderTimedOut
    case renderTooLarge
    case archiveTooLarge
    case cancelled
    case message(String)

    var errorDescription: String? {
        switch self {
        case .missingProviderKeys:
            "ProviderKeys.plist is missing from the app bundle."
        case .invalidProviderKeys:
            "ProviderKeys.plist could not be decoded."
        case .emptyProviderKey:
            "A provider key is empty in ProviderKeys.plist."
        case .invalidImage:
            "One of the selected pages is not a readable image."
        case .emptyDraft:
            "Add at least one page before starting."
        case .jobNotFound:
            "This Academic job is no longer available."
        case .malformedProviderResponse:
            "The OCR provider returned an unreadable response."
        case .providerRejected(let status):
            "The OCR provider returned HTTP \(status). Check its quota and try again."
        case .providerUnavailable:
            "The OCR provider could not be reached. Check your connection and try again."
        case .visionRequestsIncomplete(let completed, let total):
            "Vision correction paused after saving \(completed) of \(total) requests. Resume retries only the unfinished requests."
        case .refinementPageMismatch(let expected, let actual):
            "Vision correction returned \(actual) pages for a \(expected)-page job."
        case .renderTimedOut:
            "The on-device document renderer timed out."
        case .renderTooLarge:
            "The rendered PDF exceeded the on-device size limit."
        case .archiveTooLarge:
            "The export archive is too large to build safely on this device."
        case .cancelled:
            "The job was paused. You can resume it later."
        case .message(let message):
            message
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .missingProviderKeys, .invalidProviderKeys, .emptyProviderKey:
            "Add one valid Mistral key and one valid SiliconFlow key to the target resource, then rebuild the app."
        case .providerRejected, .providerUnavailable, .visionRequestsIncomplete:
            "Completed stages remain cached, so Retry will not repeat them."
        case .cancelled:
            "Open the job and tap Resume."
        default:
            nil
        }
    }
}

extension Error {
    var mathNoteSafeMessage: String {
        if self is CancellationError { return MathNoteError.cancelled.localizedDescription }
        if let error = self as? MathNoteError { return error.localizedDescription }
        return "The Academic conversion could not finish. Your completed stages are still saved."
    }
}
