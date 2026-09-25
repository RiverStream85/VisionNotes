import Foundation
import Observation
import SwiftData
import UIKit

/// Drives the Import tab: one import at a time, with visible stages and a
/// cancel button that actually stops the work.
@MainActor
@Observable
final class ImportViewModel {
    private(set) var stage: ImportStage?
    private(set) var progress: Double = 0
    private(set) var lastImportedTitle: String?
    var errorAlert: ErrorAlert?

    @ObservationIgnored private var task: Task<Void, Never>?

    var isImporting: Bool { stage != nil && stage != .complete }

    nonisolated init() {}

    // MARK: - Entry points

    func importPhoto(data: Data, fileName: String?, modelContext: ModelContext) {
        start(modelContext: modelContext) { service, progress in
            try await service.importImage(
                data: data,
                type: .photo,
                originalFileName: fileName,
                progress: progress
            )
        }
    }

    func importCameraPhoto(_ image: UIImage, modelContext: ModelContext) {
        start(modelContext: modelContext) { service, progress in
            // Encoding a full-resolution capture is slow enough to matter, so
            // it happens off the main actor before the import starts.
            let data = try await ImagePreparer.encodeJPEG(from: image)
            return try await service.importImage(
                data: data,
                type: .camera,
                originalFileName: nil,
                progress: progress
            )
        }
    }

    func importPDF(from url: URL, modelContext: ModelContext) {
        start(modelContext: modelContext) { service, progress in
            try await service.importPDF(from: url, progress: progress)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        stage = nil
        progress = 0
    }

    func dismissCompletion() {
        guard stage == .complete else { return }
        stage = nil
        progress = 0
    }

    // MARK: - Private

    private func start(
        modelContext: ModelContext,
        operation: @escaping (DocumentProcessingService, @escaping DocumentProcessingService.ProgressHandler) async throws -> LibraryDocument
    ) {
        guard !isImporting else { return }
        lastImportedTitle = nil
        stage = .preparingFile
        progress = 0

        let service = DocumentProcessingService(modelContext: modelContext)
        task = Task { [weak self] in
            do {
                let document = try await operation(service) { stage, value in
                    self?.stage = stage
                    self?.progress = value
                }
                guard !Task.isCancelled else { return }
                self?.lastImportedTitle = document.title
                self?.stage = .complete
                self?.progress = 1
            } catch {
                guard let self else { return }
                let appError = AppError.wrap(error) { AppError.ocrRequestFailed(reason: $0) }
                self.stage = nil
                self.progress = 0
                if appError != .processingCancelled {
                    self.errorAlert = ErrorAlert(appError)
                }
            }
            self?.task = nil
        }
    }
}
