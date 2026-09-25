import Foundation
import OSLog
import UIKit
import os

/// Produces the Markdown the reader shows for a page. Apple Vision still
/// supplies the text layer (boxes and PDF text); this supplies the content.
protocol PageReconstructing: Sendable {
    /// `nil` when no reconstruction is available; the page then shows Vision text.
    func markdown(forImageData data: Data) async throws -> String?
}

/// Firebird on this device. It waits for the model the Academic tab downloads
/// instead of starting a download, and keeps GPU work in the foreground.
struct FirebirdPageReconstructor: PageReconstructing {
    private let model = FirebirdLocalModel()

    func markdown(forImageData data: Data) async throws -> String? {
        guard FirebirdModelAssets.modelDirectory() != nil else { return nil }
        let model = model
        do {
            return try await ForegroundGPUWork.run {
                try await model.reconstruct(imageData: data).markdown
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Vision text is still shown; "Run OCR Again" retries the page.
            Logger(subsystem: "VisionNotes", category: "PageReconstructor")
                .error("Firebird page reconstruction failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// iOS does not allow GPU work in the background. Runs an operation only while
/// the app is active; if the app resigns active, the attempt is cancelled and
/// started again once the app is back.
enum ForegroundGPUWork {
    @MainActor
    static func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        while true {
            await waitUntilActive()
            try Task.checkCancellation()
            let attempt = Task { try await operation() }
            let resigned = OSAllocatedUnfairLock(initialState: false)
            let observer = NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
            ) { _ in
                resigned.withLock { $0 = true }
                attempt.cancel()
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            do {
                return try await withTaskCancellationHandler {
                    try await attempt.value
                } onCancel: {
                    attempt.cancel()
                }
            } catch where resigned.withLock({ $0 }) && !Task.isCancelled {
                continue
            }
        }
    }

    @MainActor
    private static func waitUntilActive() async {
        let activations = NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification)
        guard UIApplication.shared.applicationState != .active else { return }
        for await _ in activations { return }
    }
}
