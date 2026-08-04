import Foundation

/// Where a library document originally came from.
enum DocumentType: String, Codable, CaseIterable, Identifiable, Sendable {
    case camera
    case photo
    case pdf

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .camera: return "Camera"
        case .photo: return "Photo"
        case .pdf: return "PDF"
        }
    }

    var systemImageName: String {
        switch self {
        case .camera: return "camera"
        case .photo: return "photo"
        case .pdf: return "doc.richtext"
        }
    }

    /// File extension used when the source file is copied into the sandbox.
    var fileExtension: String {
        switch self {
        case .camera, .photo: return "jpg"
        case .pdf: return "pdf"
        }
    }

    var isImageBased: Bool {
        self != .pdf
    }
}

/// Lifecycle of the OCR pipeline for one document.
enum ProcessingStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case processing
    case completed
    case failed

    var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .processing: return "Processing"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }

    var systemImageName: String {
        switch self {
        case .pending: return "clock"
        case .processing: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }
}

/// Stages reported to the user while an import runs.
enum ImportStage: Int, CaseIterable, Identifiable, Sendable {
    case preparingFile
    case renderingPages
    case recognizingText
    case savingResults
    case complete

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .preparingFile: return "Preparing file"
        case .renderingPages: return "Rendering pages"
        case .recognizingText: return "Recognizing text"
        case .savingResults: return "Saving results"
        case .complete: return "Complete"
        }
    }
}
