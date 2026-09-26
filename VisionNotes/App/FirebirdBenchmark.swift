import FirebirdCore
import FirebirdRuntime
import Foundation

/// Developer benchmark for measuring Firebird on a device. Copy images into
/// Documents/Benchmark in the app container, then launch with VN_BENCHMARK=1
/// (optionally VN_BENCHMARK_TIER=reduced|standard|extended|high, and
/// VN_BENCHMARK_MODEL=paddle or paddle-spotting to load PaddleOCR-VL from
/// Documents/PaddleModel, or qwen to load Qwen3-VL from Documents/QwenModel):
///
///     xcrun devicectl device process launch --console --device <id> \
///         --environment-variables '{"VN_BENCHMARK":"1"}' com.visionnotes.VisionNotes
///
/// Each page prints one JSON line and all results go to Benchmark/results.json.
enum FirebirdBenchmark {
    static var isRequested: Bool { ProcessInfo.processInfo.environment["VN_BENCHMARK"] == "1" }

    struct Result: Codable {
        let file: String
        let loadSeconds: Double?
        let lines: Int?
        let metrics: FirebirdGenerationMetrics?
        let markdown: String?
        let error: String?
    }

    static func run() async {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Benchmark", isDirectory: true)
        let images = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["png", "jpg", "jpeg", "heic"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        print("VN_BENCHMARK start: \(images.count) images in \(folder.path)")
        let environment = ProcessInfo.processInfo.environment
        let recipe: FirebirdRecipe
        let modelDirectory: URL?
        switch environment["VN_BENCHMARK_MODEL"] {
        case "qwen":
            recipe = .academicTranscription
            modelDirectory = folder.deletingLastPathComponent().appendingPathComponent("QwenModel", isDirectory: true)
        case "paddle", "paddle-spotting":
            recipe = environment["VN_BENCHMARK_MODEL"] == "paddle" ? .paddleText : .paddleSpotting
            modelDirectory = folder.deletingLastPathComponent().appendingPathComponent("PaddleModel", isDirectory: true)
        default:
            recipe = FirebirdLocalModel.recipe
            modelDirectory = FirebirdModelAssets.modelDirectory()
        }
        guard let directory = modelDirectory else {
            print("VN_BENCHMARK error: model not present")
            return
        }

        var options = FirebirdRuntimeOptions()
        if let tier = environment["VN_BENCHMARK_TIER"].flatMap(FirebirdDeviceBudget.Tier.init) {
            options.tierCeiling = tier
        }
        let runtime = FirebirdRuntime.shared
        let loadStart = Date()
        do {
            try await runtime.load(directory: directory, options: options)
        } catch {
            print("VN_BENCHMARK error: load failed: \(error)")
            return
        }
        let loadSeconds = Date().timeIntervalSince(loadStart)
        print("VN_BENCHMARK loaded in \(String(format: "%.2f", loadSeconds)) s, tier \(await runtime.deviceBudget()?.tier.rawValue ?? "?")")

        var results: [Result] = []
        for (offset, url) in images.enumerated() {
            let result: Result
            do {
                let output = try await runtime.reconstruct(imageData: Data(contentsOf: url), recipe: recipe)
                result = Result(file: url.lastPathComponent, loadSeconds: offset == 0 ? loadSeconds : nil,
                                lines: output.lines.count, metrics: output.metrics, markdown: output.markdown, error: nil)
            } catch {
                result = Result(file: url.lastPathComponent, loadSeconds: nil, lines: nil, metrics: nil, markdown: nil,
                                error: String(describing: error))
            }
            results.append(result)
            let line = Result(file: result.file, loadSeconds: result.loadSeconds, lines: result.lines, metrics: result.metrics,
                              markdown: nil, error: result.error)
            if let json = try? JSONEncoder().encode(line) { print("VN_BENCHMARK result: " + String(decoding: json, as: UTF8.self)) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(results).write(to: folder.appendingPathComponent("results.json"))
        print("VN_BENCHMARK done")
    }
}
