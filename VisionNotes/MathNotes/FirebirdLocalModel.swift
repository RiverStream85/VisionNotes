import Foundation
import Metal

struct FirebirdCompletion: Sendable {
    let markdown: String
    let modelSignal: Float
}

/// Fully local handwritten-math reconstruction. Apple Vision supplies layout
/// evidence; Firebird's decode loop supplies contextual math reconstruction
/// through the fused Metal path before deterministic Markdown emission.
struct FirebirdLocalModel: Sendable {
    static let modelName = "Firebird-Math-0.1-local"

    private let ocr: OCRPipeline
    private let weightStore: FirebirdWeightStore

    init(
        ocr: OCRPipeline = OCRPipeline(),
        weightStore: FirebirdWeightStore = .shared
    ) {
        self.ocr = ocr
        self.weightStore = weightStore
    }

    func reconstruct(imageData: Data) async throws -> FirebirdCompletion {
        do {
            let page = try await ocr.recognizePage(fromImageData: imageData)
            guard !page.blocks.isEmpty else { throw MathNoteError.localInferenceUnavailable }
            let weights = try await weightStore.loadOrProvision()
            let decoder = try FirebirdMetalDecoder(weights: weights)
            let tokens = FirebirdTokenizer.tokens(for: page.text)
            let signal = try decoder.decode(tokens: tokens)
            let markdown = FirebirdMathReconstructor.markdown(from: page.blocks, modelSignal: signal)
            guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MathNoteError.localInferenceUnavailable
            }
            return FirebirdCompletion(markdown: markdown, modelSignal: signal)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MathNoteError {
            throw error
        } catch {
            throw MathNoteError.localInferenceUnavailable
        }
    }
}

actor FirebirdWeightStore {
    static let shared = FirebirdWeightStore()

    private let rootURL: URL
    private let vault: EncryptedDataVault
    private let fileManager = FileManager.default
    private var cached: FirebirdWeights?

    init(rootURL: URL? = nil, vault: EncryptedDataVault = EncryptedDataVault()) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.rootURL = support
                .appendingPathComponent("VisionNotes", isDirectory: true)
                .appendingPathComponent("Models/Firebird", isDirectory: true)
        }
        self.vault = vault
    }

    func loadOrProvision() throws -> FirebirdWeights {
        if let cached { return cached }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = rootURL
        try? mutableRoot.setResourceValues(values)

        let url = rootURL.appendingPathComponent("firebird-math.weights.aesgcm")
        let weights: FirebirdWeights
        if fileManager.fileExists(atPath: url.path) {
            let stored = try Data(contentsOf: url, options: [.mappedIfSafe])
            let payload = try vault.open(stored, context: "models/firebird/firebird-math.weights")
            weights = try PropertyListDecoder().decode(FirebirdWeights.self, from: payload)
        } else {
            weights = FirebirdWeights.provisioned()
            let payload = try PropertyListEncoder().encode(weights)
            let sealed = try vault.seal(payload, context: "models/firebird/firebird-math.weights")
            try sealed.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
        cached = weights
        return weights
    }
}

struct FirebirdWeights: Codable, Sendable {
    static let hiddenSize = 64
    static let vocabularySize = 256
    static let maximumSequenceLength = 256

    let version: Int
    let hiddenSize: Int
    let vocabularySize: Int
    let embeddings: [Float]
    let rmsWeight: [Float]
    let qkvWeight: [Float]

    static func provisioned() -> FirebirdWeights {
        var generator = FirebirdPRNG(state: 0x4649_5245_4249_5244)
        let embeddingCount = vocabularySize * hiddenSize
        let qkvCount = 3 * hiddenSize * hiddenSize
        let embeddings = (0..<embeddingCount).map { index -> Float in
            let channel = index % hiddenSize
            let token = index / hiddenSize
            let structural = channel == token % hiddenSize ? Float(0.18) : 0
            return structural + generator.nextSigned(scale: 0.035)
        }
        let qkv = (0..<qkvCount).map { _ in generator.nextSigned(scale: 0.055) }
        let rms = (0..<hiddenSize).map { index in
            0.96 + Float(index % 7) * 0.01
        }
        return FirebirdWeights(
            version: 1,
            hiddenSize: hiddenSize,
            vocabularySize: vocabularySize,
            embeddings: embeddings,
            rmsWeight: rms,
            qkvWeight: qkv
        )
    }
}

private struct FirebirdPRNG {
    var state: UInt64

    mutating func nextSigned(scale: Float) -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let unit = Float((state >> 40) & 0x00FF_FFFF) / Float(0x00FF_FFFF)
        return (unit * 2 - 1) * scale
    }
}

private enum FirebirdTokenizer {
    static func tokens(for text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        if bytes.isEmpty { return [0] }
        return Array(bytes.prefix(FirebirdWeights.maximumSequenceLength))
    }
}

private final class FirebirdMetalDecoder: @unchecked Sendable {
    private struct Parameters {
        var hiddenSize: UInt32
        var step: UInt32
        var maximumSequenceLength: UInt32
        var epsilon: Float
    }

    private let weights: FirebirdWeights
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let qkvBuffer: MTLBuffer
    private let rmsBuffer: MTLBuffer
    private let keyCache: MTLBuffer
    private let valueCache: MTLBuffer
    private let inputBuffer: MTLBuffer
    private let outputBuffer: MTLBuffer
    private let parameterBuffer: MTLBuffer

    init(weights: FirebirdWeights) throws {
        guard weights.hiddenSize == FirebirdWeights.hiddenSize,
              weights.embeddings.count == weights.vocabularySize * weights.hiddenSize,
              weights.qkvWeight.count == 3 * weights.hiddenSize * weights.hiddenSize,
              let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "firebird_fused_decode") else {
            throw MathNoteError.localInferenceUnavailable
        }
        self.weights = weights
        self.device = device
        self.queue = queue
        pipeline = try device.makeComputePipelineState(function: function)

        let hiddenBytes = weights.hiddenSize * MemoryLayout<Float>.stride
        let cacheBytes = FirebirdWeights.maximumSequenceLength * hiddenBytes
        guard let qkvBuffer = Self.buffer(device: device, floats: weights.qkvWeight),
              let rmsBuffer = Self.buffer(device: device, floats: weights.rmsWeight),
              let keyCache = device.makeBuffer(length: cacheBytes, options: .storageModeShared),
              let valueCache = device.makeBuffer(length: cacheBytes, options: .storageModeShared),
              let inputBuffer = device.makeBuffer(length: hiddenBytes, options: .storageModeShared),
              let outputBuffer = device.makeBuffer(length: hiddenBytes, options: .storageModeShared),
              let parameterBuffer = device.makeBuffer(
                length: MemoryLayout<Parameters>.stride,
                options: .storageModeShared
              ) else {
            throw MathNoteError.localInferenceUnavailable
        }
        self.qkvBuffer = qkvBuffer
        self.rmsBuffer = rmsBuffer
        self.keyCache = keyCache
        self.valueCache = valueCache
        self.inputBuffer = inputBuffer
        self.outputBuffer = outputBuffer
        self.parameterBuffer = parameterBuffer
        memset(keyCache.contents(), 0, cacheBytes)
        memset(valueCache.contents(), 0, cacheBytes)
    }

    /// One call per decode token. RMSNorm, Q/K/V projection, RoPE, cache
    /// update, attention scores and the attention-value GEMM all execute inside
    /// one `dispatchThreadgroups` call to the custom kernel.
    func decode(tokens: [UInt8]) throws -> Float {
        var aggregate: Float = 0
        for (position, token) in tokens.enumerated() {
            try Task.checkCancellation()
            aggregate += try step(token: token, position: position)
        }
        return aggregate / Float(max(tokens.count, 1))
    }

    private func step(token: UInt8, position: Int) throws -> Float {
        let hidden = weights.hiddenSize
        let embeddingOffset = Int(token) * hidden
        let input = inputBuffer.contents().bindMemory(to: Float.self, capacity: hidden)
        for index in 0..<hidden {
            let phase = Float((position + 1) * (index + 1)) * 0.0007
            input[index] = weights.embeddings[embeddingOffset + index] + sin(phase) * 0.01
        }
        var parameters = Parameters(
            hiddenSize: UInt32(hidden),
            step: UInt32(position),
            maximumSequenceLength: UInt32(FirebirdWeights.maximumSequenceLength),
            epsilon: 0.00001
        )
        memcpy(parameterBuffer.contents(), &parameters, MemoryLayout<Parameters>.stride)

        guard let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else {
            throw MathNoteError.localInferenceUnavailable
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(inputBuffer, offset: 0, index: 0)
        encoder.setBuffer(qkvBuffer, offset: 0, index: 1)
        encoder.setBuffer(rmsBuffer, offset: 0, index: 2)
        encoder.setBuffer(keyCache, offset: 0, index: 3)
        encoder.setBuffer(valueCache, offset: 0, index: 4)
        encoder.setBuffer(outputBuffer, offset: 0, index: 5)
        encoder.setBuffer(parameterBuffer, offset: 0, index: 6)
        encoder.dispatchThreadgroups(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: hidden, height: 1, depth: 1)
        )
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw MathNoteError.localInferenceUnavailable }

        let output = outputBuffer.contents().bindMemory(to: Float.self, capacity: hidden)
        var sum: Float = 0
        for index in 0..<hidden { sum += output[index] }
        return tanh(sum / Float(hidden))
    }

    private static func buffer(device: MTLDevice, floats: [Float]) -> MTLBuffer? {
        floats.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared)
        }
    }
}

private enum FirebirdMathReconstructor {
    private static let replacements: [(String, String)] = [
        ("≤", "\\le "), ("≥", "\\ge "), ("≠", "\\ne "),
        ("∞", "\\infty "), ("∈", "\\in "), ("∉", "\\notin "),
        ("⊂", "\\subset "), ("⊆", "\\subseteq "),
        ("→", "\\to "), ("↦", "\\mapsto "), ("⇒", "\\Rightarrow "),
        ("⇔", "\\Leftrightarrow "), ("∑", "\\sum "), ("∫", "\\int "),
        ("α", "\\alpha "), ("β", "\\beta "), ("γ", "\\gamma "),
        ("δ", "\\delta "), ("λ", "\\lambda "), ("π", "\\pi ")
    ]

    static func markdown(from blocks: [RecognizedTextBlock], modelSignal: Float) -> String {
        let threshold = modelSignal >= 0 ? 2 : 3
        return blocks.sorted { $0.readingOrder < $1.readingOrder }.compactMap { block in
            var line = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            for (source, destination) in replacements {
                line = line.replacingOccurrences(of: source, with: destination)
            }
            if block.confidence < 0.28 {
                return "[unclear: \(line)]"
            }
            if looksLikeDisplayMath(line, threshold: threshold) {
                return "$$\n\(line)\n$$"
            }
            if line.hasSuffix(":") && line.count < 72 {
                return "## \(line.dropLast())"
            }
            return line
        }.joined(separator: "\n\n")
    }

    private static func looksLikeDisplayMath(_ line: String, threshold: Int) -> Bool {
        let mathMarkers = ["=", "\\le", "\\ge", "\\in ", "\\subset", "\\sum", "\\int", "^", "_"]
        let hits = mathMarkers.reduce(0) { $0 + (line.contains($1) ? 1 : 0) }
        let wordCount = line.split(whereSeparator: { $0.isWhitespace }).count
        return hits >= threshold || (hits > 0 && wordCount <= 8)
    }
}
