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
    /// Text elements with locations, for a `.spotting` recipe; otherwise empty.
    public let lines: [FirebirdTextLine]
    /// The model's output as generated, which is what `resumingFrom` takes.
    public let output: String
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

    /// Loads a Qwen3-VL (`qwen3_vl`) or PaddleOCR-VL (`paddleocr_vl`) checkpoint.
    public func load(directory: URL, options: FirebirdRuntimeOptions = .init()) async throws {
        guard container == nil else { return }
        let data = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let modelType = raw?["model_type"] as? String
        let footprint: FirebirdModelFootprint
        switch modelType {
        case "qwen3_vl":
            let text = try JSONDecoder().decode(Qwen3VLConfiguration.self, from: data).textConfiguration
            footprint = FirebirdModelFootprint(weightBytes: try Self.weightBytes(in: directory),
                layers: text.numHiddenLayers, kvHeads: text.numKeyValueHeads, headDim: text.headDim)
        case "paddleocr_vl":
            let config = try JSONDecoder().decode(PaddleOCRVLConfiguration.self, from: data)
            footprint = FirebirdModelFootprint(weightBytes: try Self.weightBytes(in: directory),
                layers: config.numHiddenLayers, kvHeads: config.numKeyValueHeads, headDim: config.headDim)
        default:
            throw FirebirdRuntimeError.unsupportedConfiguration
        }

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
        configuration.eosTokenIds = try Self.stopTokens(in: directory)
        let tokenizer = try await loadTokenizer(configuration: configuration, hub: HubApi())
        let model: any VLMModel
        let processor: any UserInputProcessor
        if modelType == "paddleocr_vl" {
            let config = try JSONDecoder().decode(PaddleOCRVLConfiguration.self, from: data)
            var processorConfig = try JSONDecoder().decode(PaddleOCRVLProcessorConfiguration.self,
                from: Data(contentsOf: directory.appendingPathComponent("preprocessor_config.json")))
            processorConfig.maxPixels = min(processorConfig.maxPixels, budget.maxPixels)
            model = PaddleOCRVL(config)
            processor = PaddleOCRVLProcessor(processorConfig, tokenizer: tokenizer, imageTokenId: config.imageTokenId)
            decodeAttention = .mlx
        } else {
            model = Qwen3VL(try JSONDecoder().decode(Qwen3VLConfiguration.self, from: data))
            processor = Qwen3VLProcessor(try Self.processorConfiguration(in: directory, maxPixels: budget.maxPixels),
                                         tokenizer: tokenizer)
            decodeAttention = Self.verifiedDecodeAttention(options.decodeAttention, logger: logger)
        }
        let base = try JSONDecoder().decode(BaseConfiguration.self, from: data)
        // loadWeights evaluates all model tensors before temporary plaintext is removed.
        try loadWeights(modelDirectory: directory, model: model, perLayerQuantization: base.perLayerQuantization)
        (model as? Qwen3VL)?.setDecodeAttention(decodeAttention)
        logger.notice("Local model weights loaded; MLX active MiB: \(Memory.activeMemory / 1_048_576)")
        self.budget = budget
        self.options = options
        container = ModelContainer(context: .init(configuration: configuration, model: model,
            processor: processor, tokenizer: tokenizer))
    }

    /// `eos_token_id` is a list in Qwen3-VL's generation config and one id in PaddleOCR-VL's.
    static func stopTokens(in directory: URL) throws -> Set<Int> {
        let data = try Data(contentsOf: directory.appendingPathComponent("generation_config.json"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        switch object?["eos_token_id"] {
        case let id as Int: return [id]
        case let ids as [Int]: return Set(ids)
        default: throw FirebirdRuntimeError.unsupportedConfiguration
        }
    }

    static func makeInput(image: CIImage, prompt: String) -> UserInput {
        // Use structured chat: the pinned dependency’s prompt/images initializer
        // does not populate its stored image list during initialization.
        UserInput(chat: [.user(prompt, images: [.ciImage(image)])])
    }

    /// The part of an interrupted transcription that is safe to resume from:
    /// everything through its last line break.
    static func resumablePrefix(_ partial: String) -> String {
        guard let newline = partial.lastIndex(of: "\n") else { return "" }
        return String(partial[...newline])
    }

    /// Appends already generated tokens after the assistant-turn header. Both
    /// prompts end with that header (`<|im_start|>assistant\n` for Qwen3-VL,
    /// `Assistant:\n` for PaddleOCR-VL), so the tokens continue the answer.
    static func appending(_ tokens: [Int], to input: LMInput) -> LMInput {
        guard !tokens.isEmpty else { return input }
        let prefix = MLXArray(tokens.map(Int32.init)).expandedDimensions(axis: 0).asType(input.text.tokens.dtype)
        let text = concatenated([input.text.tokens, prefix], axis: 1)
        return LMInput(text: .init(tokens: text, mask: ones(like: text).asType(.int8)),
                       image: input.image, video: input.video)
    }

    /// Transcribes one page. With `partial`, the output of an interrupted run
    /// (for example the text of the last `.generating` update), generation
    /// continues after it instead of starting over: the image, prompt and the
    /// partial text as the start of the assistant turn are prefilled, and the
    /// returned Markdown includes that text. Only whole lines are reused,
    /// because a cut inside a word or LaTeX command tokenizes differently from
    /// how the model produced it.
    public func reconstruct(imageData: Data, recipe: FirebirdRecipe = .academicTranscription,
                            resumingFrom partial: String? = nil,
                            progress: (@Sendable (FirebirdProgress) async -> Void)? = nil) async throws -> FirebirdReconstruction {
        guard !isGenerating else { throw FirebirdRuntimeError.busy }
        guard let container, let budget else { throw FirebirdRuntimeError.notLoaded }
        guard CIImage(data: imageData) != nil else { throw FirebirdRuntimeError.invalidImage }
        isGenerating = true
        defer { isGenerating = false }
        try Task.checkCancellation()
        let prefix = partial.map(Self.resumablePrefix) ?? ""
        let prefixTokens = prefix.isEmpty ? [] : await container.perform { _, tokenizer in
            tokenizer.encode(text: prefix, addSpecialTokens: false)
        }

        // Refuse a page cleanly rather than risk a memory termination mid-generation.
        Memory.clearCache()
        let available = FirebirdMemory.availableBytes()
        guard available >= budget.pageHeadroom else {
            throw FirebirdRuntimeError.insufficientMemory(availableBytes: available, requiredBytes: budget.pageHeadroom)
        }
        Memory.peakMemory = 0
        let started = Date()
        var partial = ""
        for (index, decoding) in recipe.attempts.enumerated() {
            let attempt = index + 1
            await progress?(.preparingImage)
            // Preparation consumes its input and generation consumes the result,
            // so each attempt builds both from the Sendable image bytes.
            guard let image = CIImage(data: imageData) else { throw FirebirdRuntimeError.invalidImage }
            let prepared = try await container.prepare(input: Self.makeInput(image: image, prompt: recipe.prompt))
            guard prepared.image != nil else { throw FirebirdRuntimeError.invalidImage }
            let input = Self.appending(prefixTokens, to: prepared)
            let promptTokens = input.text.tokens.size
            let maxTokens = min(budget.maxContext - promptTokens - 1, options.maxOutputTokens ?? Int.max)
            guard maxTokens >= 128 else { throw FirebirdRuntimeError.contextLimit }
            await progress?(.readingPage(attempt: attempt))
            let generation = try await container.perform(nonSendable: input) { context, input in
                let sampler = GenerateParameters(temperature: decoding.temperature,
                    topP: decoding.topP, topK: decoding.topK).sampler()
                let iterator = try TokenIterator(input: input, model: context.model,
                    processor: FirebirdLogitProcessor(decoding, generatedPrefixLength: prefixTokens.count),
                    sampler: sampler, prefillStepSize: 128, maxTokens: maxTokens)
                let (stream, task) = generateTask(promptTokenCount: input.text.tokens.size,
                    modelConfiguration: context.configuration, tokenizer: context.tokenizer,
                    iterator: iterator)
                return FirebirdGeneration(stream: stream, task: task)
            }
            let outcome = try await consume(generation, prefix: prefix, attempt: attempt, started: started,
                                            progress: progress)
            switch outcome {
            case .completed(let text, let info, let firstText):
                await progress?(.finishing)
                let output = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let lines = recipe.output == .spotting ? FirebirdSpotting(parsing: output).lines : []
                let markdown = recipe.output == .spotting ? FirebirdSpotting(lines: lines).markdown : output
                guard !markdown.isEmpty else { throw FirebirdRuntimeError.incompleteGeneration }
                let metrics = FirebirdGenerationMetrics(tier: budget.tier.rawValue, maxPixels: budget.maxPixels,
                    decodeAttention: decodeAttention.rawValue, attempts: attempt, promptTokens: promptTokens,
                    generatedTokens: info.generationTokenCount,
                    timeToFirstText: firstText.map { $0.timeIntervalSince(started) } ?? 0,
                    decodeTokensPerSecond: info.tokensPerSecond, totalSeconds: Date().timeIntervalSince(started),
                    peakMemoryBytes: Memory.peakMemory)
                logger.notice("Page complete; attempts \(attempt), \(info.tokensPerSecond, format: .fixed(precision: 1)) tok/s, MLX peak MiB: \(Memory.peakMemory / 1_048_576)")
                return FirebirdReconstruction(markdown: markdown, lines: lines, output: output, metrics: metrics)
            case .outputLimit(let text):
                throw FirebirdRuntimeError.incomplete(.outputLimit, partialMarkdown: Self.draft(text, recipe: recipe))
            case .repetitionLoop(let text):
                logger.notice("Repetition loop on attempt \(attempt); \(recipe.attempts.count - attempt) attempts remain")
                partial = Self.draft(loopDetector.trimmingLoop(text), recipe: recipe)
            }
        }
        throw FirebirdRuntimeError.incomplete(.repetitionLoop, partialMarkdown: partial)
    }

    /// Readable text of an unfinished page, without location tokens.
    static func draft(_ text: String, recipe: FirebirdRecipe) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return recipe.output == .spotting ? FirebirdSpotting(parsing: text).markdown : text
    }

    private enum Outcome {
        case completed(String, GenerateCompletionInfo, firstText: Date?)
        case outputLimit(String)
        case repetitionLoop(String)
    }

    /// Collects the generated text after `prefix`, the resumed part of the page,
    /// so loop detection and progress see the page as one transcription.
    private func consume(_ generation: FirebirdGeneration, prefix: String, attempt: Int, started: Date,
                         progress: (@Sendable (FirebirdProgress) async -> Void)?) async throws -> Outcome {
        let task = generation.task
        return try await withTaskCancellationHandler {
            var text = prefix
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

/// Combines the decoding attempt's generated-only penalty and no-repeat rule.
/// When resuming, the last `generatedPrefixLength` prompt tokens are output of
/// the interrupted run; both rules see them as generated, so a resumed page is
/// decoded as if it had never stopped.
struct FirebirdLogitProcessor: LogitProcessor {
    private var penalty: GeneratedTokenPenalty?
    private var noRepeat: NoRepeatNGramBans?
    private let generatedPrefixLength: Int

    init?(_ decoding: FirebirdDecoding, generatedPrefixLength: Int = 0) {
        guard decoding.penalty != nil || decoding.noRepeatNGram != nil else { return nil }
        penalty = decoding.penalty.map(GeneratedTokenPenalty.init)
        noRepeat = decoding.noRepeatNGram.map(NoRepeatNGramBans.init)
        self.generatedPrefixLength = generatedPrefixLength
    }

    mutating func prompt(_ prompt: MLXArray) {
        let count = generatedPrefixLength
        guard count > 0 else { return }
        let generated = prompt.reshaped(-1)[(prompt.size - count)...]
        penalty?.seed(generated)
        noRepeat?.seed(generated, count: count)
    }

    func process(logits: MLXArray) -> MLXArray {
        let logits = penalty?.process(logits: logits) ?? logits
        return noRepeat?.apply(to: logits) ?? logits
    }

    mutating func didSample(token: MLXArray) {
        penalty?.didSample(token: token)
        noRepeat?.append(token)
    }
}

/// GPU form of `NoRepeatNGram`: the n-gram match and the ban are lazy MLX
/// operations, so sampling never waits for the previous token. Reading tokens
/// on the CPU instead cost 27% of decode throughput on an M4.
struct NoRepeatNGramBans {
    let rule: NoRepeatNGram
    /// The most recent generated tokens, at most `rule.window`, as int32.
    private(set) var history: MLXArray?
    /// Known on the CPU without synchronizing: one per sampled token.
    private(set) var count = 0

    init(_ rule: NoRepeatNGram) { self.rule = rule }

    /// Starts from `count` tokens that were generated before a resume.
    mutating func seed(_ tokens: MLXArray, count: Int) {
        self.count = min(count, rule.window)
        history = tokens[(tokens.size - self.count)...].asType(.int32)
    }

    mutating func append(_ token: MLXArray) {
        let token = token.reshaped(1).asType(.int32)
        var next = history.map { concatenated([$0, token]) } ?? token
        if count == rule.window { next = next[1...] } else { count += 1 }
        history = next
    }

    /// Sets the logit of every token that would repeat an n-gram to -inf.
    func apply(to logits: MLXArray) -> MLXArray {
        guard let history, count >= rule.size else { return logits }
        let prefixLength = rule.size - 1
        let starts = count - rule.size + 1
        let startIndices = MLXArray(Int32(0) ..< Int32(starts))
        let windowIndices = startIndices.expandedDimensions(axis: 1)
            + MLXArray(Int32(0) ..< Int32(prefixLength)).expandedDimensions(axis: 0)
        let windows = take(history, windowIndices, axis: 0)
        let prefix = history[(count - prefixLength)...]
        let matches = all(windows .== prefix.expandedDimensions(axis: 0), axis: 1)
        let candidates = take(history, startIndices + Int32(prefixLength), axis: 0)
        // Scatter-minimum keeps the ban when a candidate appears more than once.
        let bans = which(matches, MLXArray(-Float.infinity), MLXArray(Float.infinity))
        let flat = logits.reshaped(-1).at[candidates].minimum(bans)
        return flat.reshaped(logits.shape)
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
    /// Loads tokens generated before a resume into the window.
    mutating func seed(_ generated: MLXArray) { base.prompt(generated) }
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
