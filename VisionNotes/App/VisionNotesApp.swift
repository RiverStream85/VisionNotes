import SwiftData
import SwiftUI
import UIKit

@main
struct VisionNotesApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var obscuresSensitiveContent = true
    private let containerResult: ModelContainerProvider.Result

    init() {
        // UI tests run against a clean, in-memory library.
        let isUITesting = ProcessInfo.processInfo.arguments.contains("-uiTesting")
        FirebirdModelAssets.purgeTemporaryFiles()
        containerResult = ModelContainerProvider.makeContainer(inMemory: isUITesting)
    }

    var body: some Scene {
        WindowGroup {
            RootView(storeWarning: containerResult.warning)
                .privacySensitive()
                .overlay {
                    if obscuresSensitiveContent {
                        SensitiveContentPrivacyCover()
                    }
                }
                .task { resumeTemporaryPlaintextIfAllowed() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        resumeTemporaryPlaintextIfAllowed()
                    } else {
                        suspendAndPurgeTemporaryPlaintext()
                    }
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
                ) { _ in
                    suspendAndPurgeTemporaryPlaintext()
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
                ) { _ in
                    suspendAndPurgeTemporaryPlaintext()
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.protectedDataWillBecomeUnavailableNotification
                    )
                ) { _ in
                    suspendAndPurgeTemporaryPlaintext()
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
                ) { _ in
                    resumeTemporaryPlaintextIfAllowed()
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.protectedDataDidBecomeAvailableNotification
                    )
                ) { _ in
                    resumeTemporaryPlaintextIfAllowed()
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: .visionNotesWillSuspendPlaintext)
                ) { _ in
                    if !TemporaryPlaintextAccessController.shared.isAvailable {
                        obscuresSensitiveContent = true
                    }
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: .visionNotesDidResumePlaintext)
                ) { _ in
                    guard UIApplication.shared.applicationState == .active,
                          UIApplication.shared.isProtectedDataAvailable,
                          TemporaryPlaintextAccessController.shared.isAvailable else { return }
                    obscuresSensitiveContent = false
                }
        }
        .modelContainer(containerResult.container)
    }

    private func suspendAndPurgeTemporaryPlaintext() {
        obscuresSensitiveContent = true
        TemporaryPlaintextAccessController.shared.suspendAndPurge {
            FileStorageService.shared.purgeMaterializedFiles()
            MathNoteJobStore.purgeProcessMaterializedFiles()
            FirebirdModelAssets.purgeTemporaryFiles()
        }
    }

    private func resumeTemporaryPlaintextIfAllowed() {
        guard UIApplication.shared.applicationState == .active,
              UIApplication.shared.isProtectedDataAvailable else {
            suspendAndPurgeTemporaryPlaintext()
            return
        }
        TemporaryPlaintextAccessController.shared.resume()
        // Initial appearance can precede notification subscription. Read the
        // gate directly too, while still waiting for any pending purge.
        obscuresSensitiveContent = !TemporaryPlaintextAccessController.shared.isAvailable
    }
}

private struct SensitiveContentPrivacyCover: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Vision Notes is locked")
                    .font(.headline)
                Text("Return to the app to view your notes.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Vision Notes is locked")
    }
}
