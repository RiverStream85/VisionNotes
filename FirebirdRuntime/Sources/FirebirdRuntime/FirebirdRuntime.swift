import CoreImage
import Foundation
import OSLog
import Hub
import MLX
import MLXLMCommon
import MLXNN

public enum FirebirdRuntimeError: Error {
    case invalidImage, unsupportedConfiguration, contextLimit, incompleteGeneration, busy
    case outputLimit(partialMarkdown: String)
}

/// Firebird is the app's local inference module, not a separately trained model.
/// All loaders here accept only a local directory. Model provisioning is owned by the app.
public actor FirebirdRuntime {
    public static let shared = FirebirdRuntime()
    public static let modelIdentifier = "mlx-community/Qwen3-VL-2B-Instruct-4bit"
    private let logger = Logger(subsystem: "VisionNotes", category: "FirebirdRuntime")
    private var container: ModelContainer?
    private var isGenerating = false

    #if DEBUG
    public static func validateDeviceKernel() throws {
        try FirebirdFusedAttention.validateNumerics()
    }
    #endif

    public func isLoaded() -> Bool { container != nil }

    public func load(directory: URL) async throws {
        guard container == nil else { return }
        // Bound reusable GPU buffers on mobile; model tensors remain resident.
        Memory.cacheLimit = 32 * 1024 * 1024
        logger.notice("Loading local model")
        let data = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        let config = try JSONDecoder().decode(Qwen3VLConfiguration.self, from: data)
        // The pinned checkpoint is independently hash-verified by the app.
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text = raw?["text_config"] as? [String: Any]
        guard raw?["model_type"] as? String == "qwen3_vl",
              text?["head_dim"] as? Int == 128,
              text?["num_attention_heads"] as? Int == 16,
              text?["num_key_value_heads"] as? Int == 8,
              text?["num_hidden_layers"] as? Int == 28 else {
            throw FirebirdRuntimeError.unsupportedConfiguration
        }
        var configuration = ModelConfiguration(directory: directory)
        // Honor every stop token in the pinned checkpoint, including end-of-text.
        struct GenerationConfig: Decodable {
            let eos_token_id: [Int]
        }
        let generationConfig = try JSONDecoder().decode(GenerationConfig.self,
            from: Data(contentsOf: directory.appendingPathComponent("generation_config.json")))
        configuration.eosTokenIds = Set(generationConfig.eos_token_id)
        let tokenizer = try await loadTokenizer(configuration: configuration, hub: HubApi())
        let processorData = try Data(contentsOf: directory.appendingPathComponent("preprocessor_config.json"))
        let processorConfig = try JSONDecoder().decode(Qwen3VLProcessorConfiguration.self, from: processorData)
        let model = Qwen3VL(config)
        let base = try JSONDecoder().decode(BaseConfiguration.self, from: data)
        try loadWeights(modelDirectory: directory, model: model, perLayerQuantization: base.perLayerQuantization)
        logger.notice("Local model weights loaded")
        // loadWeights evaluates all model tensors before temporary plaintext is removed.
        container = ModelContainer(context: .init(configuration: configuration, model: model,
            processor: Qwen3VLProcessor(processorConfig, tokenizer: tokenizer), tokenizer: tokenizer))
    }

    static func makeInput(image: CIImage) -> UserInput {
        // Use structured chat: the pinned dependency’s prompt/images initializer
        // does not populate its stored image list during initialization.
        return UserInput(chat: [.user("""
            Transcribe this handwritten academic page faithfully into Markdown with LaTeX mathematics.
            Preserve the reading order, headings, all formulas, subscripts, superscripts and matrices.
            Use $...$ for inline math and $$...$$ for display math. Do not solve, summarize, or invent text.
            Mark genuinely unreadable content [unclear: description]. Return only the document, without a code fence.
            """, images: [.ciImage(image)])])
    }

    public func reconstruct(imageData: Data, progress: (@Sendable (String) async -> Void)? = nil) async throws -> String {
        guard !isGenerating else { throw FirebirdRuntimeError.busy }
        guard let container else { throw FirebirdRuntimeError.unsupportedConfiguration }
        guard let image = CIImage(data: imageData) else { throw FirebirdRuntimeError.invalidImage }
        isGenerating = true
        defer { isGenerating = false }
        try Task.checkCancellation()
        let user = Self.makeInput(image: image)
        await progress?("Preparing page image")
        logger.notice("Preparing page image")
        let input = try await container.prepare(input: user)
        guard input.image != nil else { throw FirebirdRuntimeError.invalidImage }
        let outputBudget = min(FirebirdFusedAttention.maximumContext - input.text.tokens.size - 1,
            FirebirdAttentionDiagnostics.outputLimit ?? Int.max)
        guard outputBudget >= 128 else {
            throw FirebirdRuntimeError.contextLimit
        }
        await progress?("Reading page · waiting for first text")
        Memory.clearCache()
        Memory.peakMemory = 0
        logger.notice("Starting local generation; MLX active MiB: \(Memory.activeMemory / 1_048_576)")
        let stream = try await container.perform(nonSendable: input) { context, input in
            let parameters = GenerateParameters(maxTokens: outputBudget, temperature: 0.7,
                topP: 0.8, topK: 20, prefillStepSize: 128)
            let iterator = try TokenIterator(input: input, model: context.model,
                processor: FirebirdPresencePenalty(), sampler: parameters.sampler(),
                prefillStepSize: 128, maxTokens: outputBudget)
            return generateTask(promptTokenCount: input.text.tokens.size,
                modelConfiguration: context.configuration, tokenizer: context.tokenizer,
                iterator: iterator).0
        }
        var result = ""
        var stopReason: GenerateStopReason?
        var reportedFirstChunk = false
        var lastReport = Date.distantPast
        let started = Date()
        var characterCount = 0
        for await event in stream {
            try Task.checkCancellation()
            switch event {
            case .chunk(let chunk):
                if !reportedFirstChunk {
                    logger.notice("Local generation produced first text; MLX peak MiB: \(Memory.peakMemory / 1_048_576)")
                    reportedFirstChunk = true
                }
                result += chunk
                characterCount += chunk.count
                if Date().timeIntervalSince(lastReport) >= 1 {
                    lastReport = Date()
                    FirebirdAttentionDiagnostics.capturePartial?(result)
                    let seconds = Int(lastReport.timeIntervalSince(started))
                    await progress?("Reconstructing · \(characterCount) characters · \(seconds)s")
                    logger.notice("Generation progress: \(characterCount) characters, \(seconds)s")
                }
            case .info(let info): stopReason = info.stopReason
            default: break
            }
        }
        try Task.checkCancellation()
        logger.notice("Generation stream finished; MLX peak MiB: \(Memory.peakMemory / 1_048_576)")
        await progress?("Checking completed reconstruction")
        let markdown = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty else { throw FirebirdRuntimeError.incompleteGeneration }
        switch stopReason {
        case .stop: break
        case .length: throw FirebirdRuntimeError.outputLimit(partialMarkdown: markdown)
        case .cancelled, .none: throw FirebirdRuntimeError.incompleteGeneration
        }
        return markdown
    }
}

/// The pinned MLX penalty ring expects a flat prompt. VLM processors supply [1, N].
/// Normalize only the penalty's view; the vision model keeps its batched tokens.
struct FirebirdPresencePenalty: LogitProcessor {
    private var penalty = PresencePenaltyContext(presencePenalty: 1.5, presenceContextSize: 4096)
    mutating func prompt(_ prompt: MLXArray) { penalty.prompt(prompt.reshaped(-1)) }
    func process(logits: MLXArray) -> MLXArray { penalty.process(logits: logits) }
    mutating func didSample(token: MLXArray) { penalty.didSample(token: token) }
}
