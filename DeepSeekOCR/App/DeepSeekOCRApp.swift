import SwiftUI

@main
struct DeepSeekOCRApp: App {
    @State private var viewModel = OCRViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .task {
                    let arguments = ProcessInfo.processInfo.arguments
                    guard arguments.contains("--auto-ocr-test") else {
                        return
                    }
                    let runID: String
                    if let marker = arguments.firstIndex(of: "--smoke-run-id"),
                       arguments.indices.contains(marker + 1) {
                        runID = arguments[marker + 1]
                    } else {
                        runID = "unspecified"
                    }
                    viewModel.performanceMode = arguments.contains("--fast-ocr-test")
                        ? .fast
                        : .accurate
                    viewModel.prepareSmokeTestReport(runID: runID)
                    await viewModel.loadMathFixture()
                    viewModel.runOCR(saveSmokeTestReport: true, smokeRunID: runID)
                }
        }
    }
}
