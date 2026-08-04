import SwiftData
import SwiftUI

@main
struct VisionNotesApp: App {
    private let containerResult: ModelContainerProvider.Result

    init() {
        // UI tests run against a clean, in-memory library.
        let isUITesting = ProcessInfo.processInfo.arguments.contains("-uiTesting")
        containerResult = ModelContainerProvider.makeContainer(inMemory: isUITesting)
    }

    var body: some Scene {
        WindowGroup {
            RootView(storeWarning: containerResult.warning)
        }
        .modelContainer(containerResult.container)
    }
}
