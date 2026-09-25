import CoreImage
import FirebirdCore
import Foundation
import OSLog
import Hub
import MLX
import MLXLMCommon
import MLXNN
#if os(iOS)
import os
#endif

public enum FirebirdRuntimeError: Error {
    case invalidImage, unsupportedConfiguration, contextLimit, incompleteGeneration, busy, notLoaded
    /// The process cannot hold the model plus one page without risking termination.
    case insufficientMemory(availableBytes: Int, requiredBytes: Int)
    /// Generation stopped early; the partial text may be kept as a draft.
    case incomplete(FirebirdIncompleteReason, partialMarkdown: String)
}

public enum FirebirdIncompleteReason: String, Sendable {
    case outputLimit, repetitionLoop
}

public struct FirebirdRuntimeOptions: Sendable {
    public var decodeAttention: FirebirdDecodeAttention
    public var tierCeiling: FirebirdDeviceBudget.Tier
    /// Development cap for regression runs; nil uses the whole context budget.
    public var maxOutputTokens: Int?

    public init(decodeAttention: FirebirdDecodeAttention = .mlx,
                tierCeiling: FirebirdDeviceBudget.Tier = FirebirdDeviceBudget.defaultCeiling,
                maxOutputTokens: Int? = nil) {
        self.decodeAttention = decodeAttention; self.tierCeiling = tierCeiling; self.maxOutputTokens = maxOutputTokens
    }
}

/// Status updates carry no page content except the model's own partial output.
public enum FirebirdProgress: Sendable {
    case preparingImage
    case readingPage(attempt: Int)
    case generating(text: String, elapsed: TimeInterval, attempt: Int)
    case finishing
}

/// Measurements for one page, reported by the evaluation harness.
public struct FirebirdGenerationMetrics: Codable, Sendable {
    public let tier: String
    public let maxPixels: Int
    public let decodeAttention: String
    public let attempts: Int
    public let promptTokens: Int
    public let generatedTokens: Int
    /// Image preparation, vision encoding and prefill, until the first text.
    public let timeToFirstText: TimeInterval
    public let decodeTokensPerSecond: Double
    public let totalSeconds: TimeInterval
    public let peakMemoryBytes: Int
}

public struct FirebirdReconstruction: Sendable {
    public let markdown: String
    public let metrics: FirebirdGenerationMetrics
}

/// Firebird is the app's local inference module, not a separately trained model.
/// All loaders here accept only a local directory. Model provisioning is owned by the app.
public actor FirebirdRuntime {
    public static let shared = FirebirdRuntime()
    private let logger = Logger(subsystem: "VisionNotes", category: "FirebirdRuntime")
    private let loopDetector = RepetitionLoopDetector()
    private var container: ModelContainer?
    private var budget: FirebirdDeviceBudget?
    private var options = FirebirdRuntimeOptions()
    private var decodeAttention = FirebirdDecodeAttention.mlx
    private var isGenerating = false

    public init() {}

    public func isLoaded() -> Bool { container != nil }

    /// The limits chosen for this device at load time.
    public func deviceBudget() -> FirebirdDeviceBudget? { budget }

    public func load(directory: URL, options: FirebirdRuntimeOptions = .init()) async throws {
        guard container == nil else { return }
        let data = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard raw?["model_type"] as? String == "qwen3_vl" else { throw FirebirdRuntimeError.unsupportedConfiguration }
        let config = try JSONDecoder().decode(Qwen3VLConfiguration.self, from: data)
        let text = config.textConfiguration
        let footprint = FirebirdModelFootprint(weightBytes: try Self.weightBytes(in: directory),
            layers: text.numHiddenLayers, kvHeads: text.numKeyValueHeads, headDim: text.headDim)

        // Size resolution and context from what this process may use, measured
        // before the weights are resident, instead of from a device name.
        let available = FirebirdMemory.availableBytes()
        guard let budget = FirebirdDeviceBudget.select(footprint: footprint, available: available,
                                                       ceiling: options.tierCeiling) else {
            let minimum = FirebirdDeviceBudget(tier: .reduced, footprint: footprint, available: 0)
            throw FirebirdRuntimeError.insufficientMemory(availableBytes: available,
                requiredBytes: footprint.weightBytes + minimum.pageHeadroom)
        }
        Memory.memoryLimit = budget.memoryLimit
        Memory.cacheLimit = budget.cacheLimit
        logger.notice("Loading local model; tier \(budget.tier.rawValue, privacy: .public), available MiB: \(available / 1_048_576)")

        var configuration = ModelConfiguration(directory: directory)
        // Honor every stop token in the checkpoint, including end-of-text.
        struct GenerationConfig: Decodable { let eos_token_id: [Int] }
        let generationConfig = try JSONDecoder().decode(GenerationConfig.self,
            from: Data(contentsOf: directory.appendingPathComponent("generation_config.json")))
        configuration.eosTokenIds = Set(generationConfig.eos_token_id)
        let tokenizer = try await loadTokenizer(configuration: configuration, hub: HubApi())
        let processorConfig = try Self.processorConfiguration(in: directory, maxPixels: budget.maxPixels)
        let model = Qwen3VL(config)
        let base = try JSONDecoder().decode(BaseConfiguration.self, from: data)
        // loadWeights evaluates all model tensors before temporary plaintext is removed.
        try loadWeights(modelDirectory: directory, model: model, perLayerQuantization: base.perLayerQuantization)
        decodeAttention = Self.verifiedDecodeAttention(options.decodeAttention, logger: logger)
        model.setDecodeAttention(decodeAttention)
        logger.notice("Local model weights loaded; MLX active MiB: \(Memory.activeMemory / 1_048_576)")
        self.budget = budget
        self.options = options
        container = ModelContainer(context: .init(configuration: configuration, model: model,
            processor: Qwen3VLProcessor(processorConfig, tokenizer: tokenizer), tokenizer: tokenizer))
    }

    static func makeInput(image: CIImage, prompt: String) -> UserInput {
        // Use structured chat: the pinned dependency’s prompt/images initializer
        // does not populate its stored image list during initialization.
        UserInput(chat: [.user(prompt, images: [.ciImage(image)])])
    }

    public func reconstruct(imageData: Data, recipe: FirebirdRecipe = .academicTranscription,
                            progress: (@Sendable (FirebirdProgress) async -> Void)? = nil) async throws -> FirebirdReconstruction {
        guard !isGenerating else { throw FirebirdRuntimeError.busy }
        guard let container, let budget else { throw FirebirdRuntimeError.notLoaded }
        guard let image = CIImage(data: imageData) else { throw FirebirdRuntimeError.invalidImage }
        isGenerating = true
        defer { isGenerating = false }
        try Task.checkCancellation()

        // Refuse a page cleanly rather than risk a memory termination mid-generation.
        Memory.clearCache()
        let available = FirebirdMemory.availableBytes()
        guard available >= budget.pageHeadroom else {
            throw FirebirdRuntimeError.insufficientMemory(availableBytes: available, requiredBytes: budget.pageHeadroom)
        }
        Memory.peakMemory = 0
        let started = Date()
        let user = Self.makeInput(image: image, prompt: recipe.prompt)
        var partial = ""
        for (index, decoding) in recipe.attempts.enumerated() {
            let attempt = index + 1
            await progress?(.preparingImage)
            // The prepared input is consumed by generation, so each attempt prepares its own.
            let input = try await container.prepare(input: user)
            guard input.image != nil else { throw FirebirdRuntimeError.invalidImage }
            let promptTokens = input.text.tokens.size
            let maxTokens = min(budget.maxContext - promptTokens - 1, options.maxOutputTokens ?? Int.max)
            guard maxTokens >= 128 else { throw FirebirdRuntimeError.contextLimit }
            await progress?(.readingPage(attempt: attempt))
            let generation = try await container.perform(nonSendable: input) { context, input in
                let sampler = GenerateParameters(temperature: decoding.temperature,
                    topP: decoding.topP, topK: decoding.topK).sampler()
                let iterator = try TokenIterator(input: input, model: context.model,
                    processor: decoding.penalty.map(GeneratedTokenPenalty.init), sampler: sampler,
                    prefillStepSize: 128, maxTokens: maxTokens)
                let (stream, task) = generateTask(promptTokenCount: input.text.tokens.size,
                    modelConfiguration: context.configuration, tokenizer: context.tokenizer,
                    iterator: iterator)
                return FirebirdGeneration(stream: stream, task: task)
            }
            let outcome = try await consume(generation, attempt: attempt, started: started, progress: progress)
            switch outcome {
            case .completed(let text, let info, let firstText):
                await progress?(.finishing)
                let markdown = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !markdown.isEmpty else { throw FirebirdRuntimeError.incompleteGeneration }
                let metrics = FirebirdGenerationMetrics(tier: budget.tier.rawValue, maxPixels: budget.maxPixels,
                    decodeAttention: decodeAttention.rawValue, attempts: attempt, promptTokens: promptTokens,
                    generatedTokens: info.generationTokenCount,
                    timeToFirstText: firstText.map { $0.timeIntervalSince(started) } ?? 0,
                    decodeTokensPerSecond: info.tokensPerSecond, totalSeconds: Date().timeIntervalSince(started),
                    peakMemoryBytes: Memory.peakMemory)
                logger.notice("Page complete; attempts \(attempt), \(info.tokensPerSecond, format: .fixed(precision: 1)) tok/s, MLX peak MiB: \(Memory.peakMemory / 1_048_576)")
                return FirebirdReconstruction(markdown: markdown, metrics: metrics)
            case .outputLimit(let text):
                throw FirebirdRuntimeError.incomplete(.outputLimit,
                    partialMarkdown: text.trimmingCharacters(in: .whitespacesAndNewlines))
            case .repetitionLoop(let text):
                logger.notice("Repetition loop on attempt \(attempt); \(recipe.attempts.count - attempt) attempts remain")
                partial = loopDetector.trimmingLoop(text).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        throw FirebirdRuntimeError.incomplete(.repetitionLoop, partialMarkdown: partial)
    }

    private enum Outcome {
        case completed(String, GenerateCompletionInfo, firstText: Date?)
        case outputLimit(String)
        case repetitionLoop(String)
    }

    private func consume(_ generation: FirebirdGeneration, attempt: Int, started: Date,
                         progress: (@Sendable (FirebirdProgress) async -> Void)?) async throws -> Outcome {
        let task = generation.task
        return try await withTaskCancellationHandler {
            var text = ""
            var info: GenerateCompletionInfo?
            var firstText: Date?
            var lastReport = Date.distantPast
            var scalars = 0, checkedScalars = 0
            var looped = false
            stream: for await event in generation.stream {
                if Task.isCancelled { break }
                switch event {
                case .chunk(let chunk):
                    if firstText == nil {
                        firstText = Date()
                        logger.notice("First text after \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s; MLX peak MiB: \(Memory.peakMemory / 1_048_576)")
                    }
                    text += chunk
                    scalars += chunk.unicodeScalars.count
                    if scalars - checkedScalars >= 64 {
                        checkedScalars = scalars
                        if loopDetector.loop(in: text) != nil {
                            looped = true
                            task.cancel()
                            break stream
                        }
                    }
                    if Date().timeIntervalSince(lastReport) >= 1 {
                        lastReport = Date()
                        await progress?(.generating(text: text, elapsed: lastReport.timeIntervalSince(started), attempt: attempt))
                    }
                case .info(let value): info = value
                default: break
                }
            }
            // The generation task owns in-flight GPU work. Wait for it before
            // returning so nothing is submitted after the app leaves the foreground.
            task.cancel()
            await task.value
            try Task.checkCancellation()
            if looped { return .repetitionLoop(text) }
            guard let info else { throw FirebirdRuntimeError.incompleteGeneration }
            switch info.stopReason {
            case .stop: return .completed(text, info, firstText: firstText)
            case .length: return .outputLimit(text)
            case .cancelled: throw FirebirdRuntimeError.incompleteGeneration
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// The fused kernel is checked against MLX on this GPU before it is used.
    private static func verifiedDecodeAttention(_ requested: FirebirdDecodeAttention,
                                                logger: Logger) -> FirebirdDecodeAttention {
        guard requested == .fusedExperimental else { return .mlx }
        do {
            try FirebirdFusedAttention.validateNumerics()
            return .fusedExperimental
        } catch {
            logger.error("Fused decode attention failed its numerical check; using MLX attention")
            return .mlx
        }
    }

    /// Caps the processor's pixel budget without editing the checkpoint file.
    static func processorConfiguration(in directory: URL, maxPixels: Int) throws -> Qwen3VLProcessorConfiguration {
        let data = try Data(contentsOf: directory.appendingPathComponent("preprocessor_config.json"))
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FirebirdRuntimeError.unsupportedConfiguration
        }
        let configured = (object["max_pixels"] as? NSNumber)?.intValue ?? Int.max
        object["max_pixels"] = min(configured, maxPixels)
        if let minimum = (object["min_pixels"] as? NSNumber)?.intValue, minimum > maxPixels {
            object["min_pixels"] = maxPixels
        }
        return try JSONDecoder().decode(Qwen3VLProcessorConfiguration.self,
            from: JSONSerialization.data(withJSONObject: object))
    }

    static func weightBytes(in directory: URL) throws -> Int {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        return try files.filter { $0.pathExtension == "safetensors" }.reduce(0) {
            $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
    }
}

/// A running generation: its output stream plus the task that owns GPU work.
struct FirebirdGeneration: Sendable {
    let stream: AsyncStream<Generation>
    let task: Task<Void, Never>
}

enum FirebirdMemory {
    /// Bytes this process can still allocate before the system terminates it.
    static func availableBytes() -> Int {
        #if os(iOS)
        let value = Int(os_proc_available_memory())
        if value > 0 { return value }
        #endif
        // macOS has no per-process limit; use the GPU working-set recommendation.
        let physical = Int(ProcessInfo.processInfo.physicalMemory)
        let recommended = Int(GPU.deviceInfo().maxRecommendedWorkingSetSize)
        return min(physical * 3 / 4, recommended > 0 ? recommended : physical)
    }
}

/// Applies a penalty to generated tokens only. Prompt tokens never enter the
/// window, so instruction text, image placeholders and LaTeX syntax that the
/// prompt mentions are not suppressed from the first generated token.
struct GeneratedTokenPenalty: LogitProcessor {
    private var base: any LogitProcessor

    init(_ penalty: FirebirdPenalty) {
        switch penalty.kind {
        case .repetition:
            base = RepetitionContext(repetitionPenalty: penalty.value, repetitionContextSize: penalty.window)
        case .presence:
            base = PresencePenaltyContext(presencePenalty: penalty.value, presenceContextSize: penalty.window)
        }
    }

    mutating func prompt(_ prompt: MLXArray) {}
    func process(logits: MLXArray) -> MLXArray { base.process(logits: logits) }
    mutating func didSample(token: MLXArray) { base.didSample(token: token) }
}

/// Evaluates a prefill intermediate unless the task was cancelled. Skipping
/// leaves the graph lazy, so no further GPU work is submitted, and `prepare`
/// throws before anything forces evaluation. iOS rejects GPU work submitted
/// after an app enters the background, and MLX treats that as fatal.
func firebirdPrefillEval(_ arrays: [MLXArray]) {
    guard !Task.isCancelled else { return }
    eval(arrays)
}
