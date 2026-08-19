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
        case .baseOCR: "On-device OCR"
        case .refining: "Firebird reconstruction"
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
    static let currentVersion = 2

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
    /// `true` only after the user selects the cloud-fallback action for this
    /// job. Missing on version-1 manifests and therefore treated as false.
    var cloudFallbackAllowed: Bool?

    var pageCount: Int { pages.count }
    var displayedProgress: Double { stageProgress ?? stage.progress }
    var allowsCloudFallback: Bool { cloudFallbackAllowed == true }

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
        cloudFallbackAllowed = false
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
        version = 2
        provider = pages.first?.provider ?? "On-device"
        model = pages.first?.model ?? FirebirdLocalModel.modelName
        createdAt = Date()
        self.pages = pages
    }
}

struct ProviderKeys: Sendable, Equatable {
    let mistral: String
    let siliconFlow: String

    static func load(store: CloudProviderCredentialStore = .shared) throws -> ProviderKeys {
        let mistral = try store.value(for: .mistral)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let siliconFlow = try store.value(for: .qwen3VL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mistral.isEmpty, !siliconFlow.isEmpty else {
            throw MathNoteError.emptyProviderKey
        }
        return ProviderKeys(mistral: mistral, siliconFlow: siliconFlow)
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
    case localInferenceUnavailable
    case cloudFallbackNotAuthorized
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
            "Cloud fallback credentials are not saved in this device's Keychain."
        case .invalidProviderKeys:
            "A cloud fallback credential in the device Keychain could not be read."
        case .emptyProviderKey:
            "A cloud fallback credential in the device Keychain is empty."
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
        case .localInferenceUnavailable:
            "The on-device Firebird model could not finish this page. You can retry locally or explicitly allow the cloud fallback."
        case .cloudFallbackNotAuthorized:
            "Cloud OCR was not used because this job has no explicit cloud-fallback consent."
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
            "Save valid Mistral and Qwen3-VL credentials in the device Keychain before opting into cloud fallback."
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
