import Foundation

/// Every user-facing failure in the app funnels through this type so the UI can
/// show a readable message and a concrete recovery hint instead of a raw
/// `NSError` description.
enum AppError: LocalizedError, Equatable {
    case cameraUnavailable
    case cameraPermissionDenied
    case photoLoadFailed
    case unsupportedImageFormat
    case pdfOpenFailed(fileName: String)
    case pdfDamaged(fileName: String)
    case pdfPageRenderFailed(pageNumber: Int)
    case fileCopyFailed(reason: String)
    case fileWriteFailed(reason: String)
    case fileMissing(fileName: String)
    case fileDeleteFailed(reason: String)
    case ocrRequestFailed(reason: String)
    case noTextRecognized
    case persistenceSaveFailed(reason: String)
    case processingCancelled

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            return "The camera is not available on this device."
        case .cameraPermissionDenied:
            return "Vision Notes does not have permission to use the camera."
        case .photoLoadFailed:
            return "That photo could not be loaded."
        case .unsupportedImageFormat:
            return "That image format is not supported."
        case .pdfOpenFailed(let fileName):
            return "“\(fileName)” could not be opened as a PDF."
        case .pdfDamaged(let fileName):
            return "“\(fileName)” looks damaged or has no readable pages."
        case .pdfPageRenderFailed(let pageNumber):
            return "Page \(pageNumber) could not be rendered."
        case .fileCopyFailed:
            return "The file could not be copied into Vision Notes."
        case .fileWriteFailed:
            return "The file could not be saved."
        case .fileMissing(let fileName):
            return "“\(fileName)” is missing from local storage."
        case .fileDeleteFailed:
            return "Some local files could not be deleted."
        case .ocrRequestFailed:
            return "Text recognition failed."
        case .noTextRecognized:
            return "No text was recognized on this page."
        case .persistenceSaveFailed:
            return "Your changes could not be saved."
        case .processingCancelled:
            return "Processing was cancelled."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .cameraUnavailable:
            return "Use Import Photo or Import PDF instead. The Simulator has no camera."
        case .cameraPermissionDenied:
            return "Enable camera access in Settings, then try again."
        case .photoLoadFailed, .unsupportedImageFormat:
            return "Pick a JPEG, PNG, or HEIC image and try again."
        case .pdfOpenFailed, .pdfDamaged:
            return "Try a different PDF, or re-export this one."
        case .pdfPageRenderFailed:
            return "Run OCR again from the library, or re-import the document."
        case .fileCopyFailed, .fileWriteFailed:
            return "Free up some storage space and try again."
        case .fileMissing:
            return "Delete this document and import it again."
        case .fileDeleteFailed:
            return "The entry was removed from your library. Some files may remain on disk."
        case .ocrRequestFailed:
            return "Run OCR again from the library."
        case .noTextRecognized:
            return "Try a sharper image, or type the text in manually."
        case .persistenceSaveFailed:
            return "Try again. If it keeps happening, restart the app."
        case .processingCancelled:
            return nil
        }
    }

    /// Wraps an arbitrary error, preserving `AppError` values that pass through.
    static func wrap(_ error: Error, fallback: (String) -> AppError) -> AppError {
        if let appError = error as? AppError { return appError }
        if error is CancellationError { return .processingCancelled }
        return fallback(error.localizedDescription)
    }
}
