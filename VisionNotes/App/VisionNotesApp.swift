import SwiftData
import SwiftUI
import UIKit

@main
struct VisionNotesApp: App {
    @UIApplicationDelegateAdaptor(VisionNotesAppDelegate.self) private var appDelegate
    private let containerResult: ModelContainerProvider.Result

    init() {
        // UI tests run against a clean, in-memory library.
        let isUITesting = ProcessInfo.processInfo.arguments.contains("-uiTesting")
        LegacyStorageCleanup.run()
        Task.detached(priority: .utility) { FirebirdModelAssets.removeObsoleteFiles() }
        containerResult = ModelContainerProvider.makeContainer(inMemory: isUITesting)
    }

    var body: some Scene {
        WindowGroup {
            RootView(storeWarning: containerResult.warning)
                .privacySensitive()
        }
        .modelContainer(containerResult.container)
    }
}

/// Delivers background URLSession events for the model download when iOS
/// relaunches the app after the transfer finished while it was not running.
final class VisionNotesAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == FirebirdModelDownloader.sessionIdentifier else { return completionHandler() }
        FirebirdModelDownloader.shared.resumeBackgroundEvents(completionHandler: completionHandler)
    }
}
