// Port of mlx-vlm 0.7.3 `models/paddleocr_vl` (MIT) for PaddleOCR-VL-1.5:
// a NaViT-style SigLIP vision encoder with 2D rotary attention, a 2×2 patch
// merging projector, and an ERNIE-4.5-0.3B decoder with multimodal RoPE.

import CoreImage
import Foundation
import MLX
import MLXLMCommon
import MLXNN
import Tokenizers

// MARK: - Configuration

public struct PaddleOCRVLConfiguration: Codable, Sendable {
    public struct Vision: Codable, Sendable {
        public let hiddenSize: Int
        public let intermediateSize: Int
        public let numHiddenLayers: Int
        public let numAttentionHeads: Int
        public let numChannels: Int
        public let imageSize: Int
        public let patchSize: Int
        public let layerNormEps: Float
        public let spatialMergeSize: Int

        enum CodingKeys: String, CodingKey {
            case hiddenSize = "hidden_size"
            case intermediateSize = "intermediate_size"
            case numHiddenLayers = "num_hidden_layers"
            case numAttentionHeads = "num_attention_heads"
            case numChannels = "num_channels"
            case imageSize = "image_size"
            case patchSize = "patch_size"
            case layerNormEps = "layer_norm_eps"
            case spatialMergeSize = "spatial_merge_size"
        }
    }

    public struct RoPEScaling: Codable, Sendable {
        public let mropeSection: [Int]
        enum CodingKeys: String, CodingKey { case mropeSection = "mrope_section" }
    }

    public let hiddenSize: Int
    public let intermediateSize: Int
    public let numHiddenLayers: Int
    public let numAttentionHeads: Int
    public let numKeyValueHeads: Int
    public let headDim: Int
    public let rmsNormEps: Float
    public let ropeTheta: Float
    public let ropeScaling: RoPEScaling
    public let vocabSize: Int
    public let imageTokenId: Int
    public let visionConfig: Vision

    enum CodingKeys: String, CodingKey {
        case hiddenSize = "hidden_size"
        case intermediateSize = "intermediate_size"
        case numHiddenLayers = "num_hidden_layers"
        case numAttentionHeads = "num_attention_heads"
        case numKeyValueHeads = "num_key_value_heads"
        case headDim = "head_dim"
        case rmsNormEps = "rms_norm_eps"
        case ropeTheta = "rope_theta"
        case ropeScaling = "rope_scaling"
        case vocabSize = "vocab_size"
        case imageTokenId = "image_token_id"
        case visionConfig = "vision_config"
    }
}

public struct PaddleOCRVLProcessorConfiguration: Codable, Sendable {
    public let imageMean: [CGFloat]
    public let imageStd: [CGFloat]
    public let minPixels: Int
    public var maxPixels: Int
    public let patchSize: Int
    public let mergeSize: Int

    enum CodingKeys: String, CodingKey {
        case imageMean = "image_mean"
        case imageStd = "image_std"
        case minPixels = "min_pixels"
        case maxPixels = "max_pixels"
        case patchSize = "patch_size"
        case mergeSize = "merge_size"
    }
}

// MARK: - Processor

/// Builds the checkpoint's chat prompt directly instead of through its Jinja
/// template: `<|begin_of_sentence|>User: <|IMAGE_START|>` image tokens
/// `<|IMAGE_END|>{prompt}\nAssistant:\n`, as rendered by the reference.
public struct PaddleOCRVLProcessor: UserInputProcessor {
    let config: PaddleOCRVLProcessorConfiguration
    let tokenizer: any Tokenizer
    let imageTokenId: Int

    public init(_ config: PaddleOCRVLProcessorConfiguration, tokenizer: any Tokenizer, imageTokenId: Int) {
        self.config = config; self.tokenizer = tokenizer; self.imageTokenId = imageTokenId
    }

    /// The reference `smart_resize`: sides rounded to the 28-pixel factor, then
    /// scaled to fit between the pixel bounds.
    static func targetSize(height: Int, width: Int, factor: Int, minPixels: Int, maxPixels: Int) -> (Int, Int) {
        var (height, width) = (Double(height), Double(width))
        let factor = Double(factor)
        if height < factor { width = (width * factor / height).rounded(.toNearestOrEven); height = factor }
        if width < factor { height = (height * factor / width).rounded(.toNearestOrEven); width = factor }
        var hBar = (height / factor).rounded(.toNearestOrEven) * factor
        var wBar = (width / factor).rounded(.toNearestOrEven) * factor
        if hBar * wBar > Double(maxPixels) {
            let beta = (height * width / Double(maxPixels)).squareRoot()
            hBar = (height / beta / factor).rounded(.down) * factor
            wBar = (width / beta / factor).rounded(.down) * factor
        } else if hBar * wBar < Double(minPixels) {
            let beta = (Double(minPixels) / (height * width)).squareRoot()
            hBar = (height * beta / factor).rounded(.up) * factor
            wBar = (width * beta / factor).rounded(.up) * factor
        }
        return (Int(hBar), Int(wBar))
    }

    /// Normalized patches in raster order, `[h * w, channels, patch, patch]`.
    func preprocess(_ image: CIImage) -> (MLXArray, THW) {
        let (height, width) = Self.targetSize(height: Int(image.extent.height), width: Int(image.extent.width),
            factor: config.patchSize * config.mergeSize, minPixels: config.minPixels, maxPixels: config.maxPixels)
        let pixels = MediaProcessing.asMLXArray(image.toSRGB()
            .resampled(to: CGSize(width: width, height: height), method: .bicubic)
            .normalized(mean: (config.imageMean[0], config.imageMean[1], config.imageMean[2]),
                        std: (config.imageStd[0], config.imageStd[1], config.imageStd[2])))
        let patch = config.patchSize
        let (gridH, gridW) = (height / patch, width / patch)
        let patches = pixels.reshaped(3, gridH, patch, gridW, patch)
            .transposed(1, 3, 0, 2, 4)
            .reshaped(gridH * gridW, 3, patch, patch)
        return (patches, THW(1, gridH, gridW))
    }

    public func prepare(input: UserInput) async throws -> LMInput {
        guard input.images.count == 1 else { throw VLMError.singleImageAllowed }
        let prompt: String
        switch input.prompt {
        case .text(let text): prompt = text
        case .chat(let messages): prompt = messages.last { $0.role == .user }?.content ?? ""
        case .messages(let messages): prompt = messages.last?["content"] as? String ?? ""
        }
        let (patches, grid) = preprocess(try input.images[0].asCIImage())
        let imageTokens = grid.product / (config.mergeSize * config.mergeSize)
        let tokens = tokenizer.encode(text: "<|begin_of_sentence|>User: <|IMAGE_START|>", addSpecialTokens: false)
            + Array(repeating: imageTokenId, count: imageTokens)
            + tokenizer.encode(text: "<|IMAGE_END|>\(prompt)\nAssistant:\n", addSpecialTokens: false)
        let array = MLXArray(tokens.map(Int32.init)).expandedDimensions(axis: 0)
        return LMInput(text: .init(tokens: array, mask: ones(like: array).asType(.int8)),
                       image: .init(pixels: patches, frames: [grid]))
    }
}

/// RoPE inverse frequencies `1 / base^(2i / dimensions)`. Kept as Swift
/// floats: an `MLXArray` property of a `Module` would be taken for a weight.
func paddleInverseFrequencies(dimensions: Int, base: Double) -> [Float] {
    stride(from: 0, to: dimensions, by: 2).map { Float(1 / pow(base, Double($0) / Double(dimensions))) }
}

// MARK: - Vision

enum PaddleOCRVLVision {

    static func rotateHalf(_ x: MLXArray) -> MLXArray {
        let half = x.dim(-1) / 2
        return concatenated([-x[.ellipsis, half...], x[.ellipsis, ..<half]], axis: -1)
    }

    /// torch `interpolate(mode: "bilinear", align_corners: false)` over the
    /// first two axes, as the reference model resizes its 27×27 position grid.
    static func bilinear(_ grid: MLXArray, height: Int, width: Int) -> MLXArray {
        func axis(_ output: Int, _ input: Int) -> (MLXArray, MLXArray, MLXArray) {
            let position = maximum((MLXArray(0 ..< output).asType(.float32) + 0.5) * (Float(input) / Float(output)) - 0.5, 0)
            let low = floor(position).asType(.int32)
            return (low, minimum(low + 1, input - 1), position - low.asType(.float32))
        }
        let (r0, r1, rw) = axis(height, grid.dim(0))
        let (c0, c1, cw) = axis(width, grid.dim(1))
        let grid = grid.asType(.float32)
        let rows = grid[r0] * (1 - rw)[0..., .newAxis, .newAxis] + grid[r1] * rw[0..., .newAxis, .newAxis]
        return rows[0..., c0] * (1 - cw)[.newAxis, 0..., .newAxis] + rows[0..., c1] * cw[.newAxis, 0..., .newAxis]
    }

    final class Embeddings: Module {
        @ModuleInfo(key: "patch_embedding") var patchEmbedding: Conv2d
        @ModuleInfo(key: "position_embedding") var positionEmbedding: Embedding
        let side: Int

        init(_ config: PaddleOCRVLConfiguration.Vision) {
            side = config.imageSize / config.patchSize
            _patchEmbedding.wrappedValue = Conv2d(inputChannels: config.numChannels, outputChannels: config.hiddenSize,
                kernelSize: .init(config.patchSize), stride: .init(config.patchSize))
            _positionEmbedding.wrappedValue = Embedding(embeddingCount: side * side, dimensions: config.hiddenSize)
        }

        func callAsFunction(_ patches: MLXArray, grid: THW) -> MLXArray {
            let dtype = patchEmbedding.weight.dtype
            let embedded = patchEmbedding(patches.asType(dtype).transposed(0, 2, 3, 1)).reshaped(patches.dim(0), -1)
            let table = positionEmbedding(MLXArray(0 ..< (side * side))).reshaped(side, side, -1)
            let positions = bilinear(table, height: grid.h, width: grid.w).asType(table.dtype)
            return embedded + positions.reshaped(grid.h * grid.w, -1)
        }
    }

    final class Attention: Module {
        let heads: Int
        let scale: Float
        @ModuleInfo(key: "qkv") var qkv: Linear
        @ModuleInfo(key: "out_proj") var outProj: Linear

        init(dimensions: Int, heads: Int) {
            self.heads = heads
            scale = pow(Float(dimensions / heads), -0.5)
            _qkv.wrappedValue = Linear(dimensions, dimensions * 3)
            _outProj.wrappedValue = Linear(dimensions, dimensions)
        }

        /// `cos` and `sin` are `[length, 1, headDim]`; one image attends to all
        /// of its patches, so there is no mask.
        ///
        /// Heads are zero-padded from 72 to 80 dimensions for attention: MLX
        /// Swift 0.31 has no fused full-attention kernel for 72 and falls back
        /// to one twice as slow (about 1 s of a 4,992-patch image). Zero
        /// dimensions change neither the scores nor the kept output columns.
        func callAsFunction(_ x: MLXArray, cos: MLXArray, sin: MLXArray) -> MLXArray {
            let length = x.dim(0)
            let parts = qkv(x).reshaped(length, 3, heads, -1)
            let headDim = parts.dim(-1)
            let padding: [IntOrPair] = [0, 0, 0, .init((0, 80 - headDim))]
            func perHead(_ t: MLXArray) -> MLXArray {
                padded(t.transposed(1, 0, 2).expandedDimensions(axis: 0), widths: padding)
            }
            func rotated(_ t: MLXArray) -> MLXArray { perHead(((t * cos) + (rotateHalf(t) * sin)).asType(x.dtype)) }
            let output = MLXFast.scaledDotProductAttention(
                queries: rotated(parts[0..., 0]), keys: rotated(parts[0..., 1]), values: perHead(parts[0..., 2]),
                scale: scale, mask: .none)
            return outProj(output[0, 0..., 0..., ..<headDim].transposed(1, 0, 2).reshaped(length, -1))
        }
    }

    final class MLP: Module, UnaryLayer {
        @ModuleInfo(key: "fc1") var fc1: Linear
        @ModuleInfo(key: "fc2") var fc2: Linear

        init(dimensions: Int, hidden: Int) {
            _fc1.wrappedValue = Linear(dimensions, hidden)
            _fc2.wrappedValue = Linear(hidden, dimensions)
        }

        func callAsFunction(_ x: MLXArray) -> MLXArray { fc2(geluApproximate(fc1(x))) }
    }

    final class EncoderLayer: Module {
        @ModuleInfo(key: "layer_norm1") var norm1: LayerNorm
        @ModuleInfo(key: "layer_norm2") var norm2: LayerNorm
        @ModuleInfo(key: "self_attn") var attention: Attention
        @ModuleInfo(key: "mlp") var mlp: MLP

        init(_ config: PaddleOCRVLConfiguration.Vision) {
            _norm1.wrappedValue = LayerNorm(dimensions: config.hiddenSize, eps: 1e-6)
            _norm2.wrappedValue = LayerNorm(dimensions: config.hiddenSize, eps: 1e-6)
            _attention.wrappedValue = Attention(dimensions: config.hiddenSize, heads: config.numAttentionHeads)
            _mlp.wrappedValue = MLP(dimensions: config.hiddenSize, hidden: config.intermediateSize)
        }

        func callAsFunction(_ x: MLXArray, cos: MLXArray, sin: MLXArray) -> MLXArray {
            let h = x + attention(norm1(x), cos: cos, sin: sin)
            return h + mlp(norm2(h))
        }
    }

    final class Projector: Module {
        let merge: Int
        @ModuleInfo(key: "pre_norm") var preNorm: LayerNorm
        @ModuleInfo(key: "linear_1") var linear1: Linear
        @ModuleInfo(key: "linear_2") var linear2: Linear

        init(_ config: PaddleOCRVLConfiguration.Vision, outputDimensions: Int) {
            merge = config.spatialMergeSize
            let merged = config.hiddenSize * merge * merge
            _preNorm.wrappedValue = LayerNorm(dimensions: config.hiddenSize, eps: 1e-6)
            _linear1.wrappedValue = Linear(merged, merged)
            _linear2.wrappedValue = Linear(merged, outputDimensions)
        }

        /// Concatenates each 2×2 block of raster-ordered patches into one token.
        func callAsFunction(_ x: MLXArray, grid: THW) -> MLXArray {
            let d = x.dim(-1)
            let blocks = preNorm(x).reshaped(grid.h / merge, merge, grid.w / merge, merge, d)
                .transposed(0, 2, 1, 3, 4)
                .reshaped(-1, merge * merge * d)
            return linear2(gelu(linear1(blocks)))
        }
    }

    final class VisionModel: Module {
        @ModuleInfo(key: "embeddings") var embeddings: Embeddings
        @ModuleInfo(key: "layers") var layers: [EncoderLayer]
        @ModuleInfo(key: "post_layernorm") var postLayerNorm: LayerNorm
        @ModuleInfo(key: "projector") var projector: Projector
        let inverseFrequency: [Float]

        init(_ config: PaddleOCRVLConfiguration.Vision, outputDimensions: Int) {
            inverseFrequency = paddleInverseFrequencies(dimensions: config.hiddenSize / config.numAttentionHeads / 2,
                                                        base: 10_000)
            _embeddings.wrappedValue = Embeddings(config)
            _layers.wrappedValue = (0 ..< config.numHiddenLayers).map { _ in EncoderLayer(config) }
            _postLayerNorm.wrappedValue = LayerNorm(dimensions: config.hiddenSize, eps: config.layerNormEps)
            _projector.wrappedValue = Projector(config, outputDimensions: outputDimensions)
        }

        /// Rotary angles per patch: row frequencies, then column frequencies.
        func rotaryAngles(_ grid: THW) -> MLXArray {
            let table = outer(MLXArray(0 ..< max(grid.h, grid.w)).asType(.float32), MLXArray(inverseFrequency))
            let index = MLXArray(0 ..< (grid.h * grid.w)).asType(.int32)
            return concatenated([table[floorDivide(index, Int32(grid.w))], table[index % Int32(grid.w)]], axis: -1)
        }

        func callAsFunction(_ patches: MLXArray, grid: THW) -> MLXArray {
            var hidden = embeddings(patches, grid: grid)
            let angles = tiled(rotaryAngles(grid), repetitions: [1, 2]).expandedDimensions(axis: 1)
            let (cosine, sine) = (cos(angles), sin(angles))
            for layer in layers {
                hidden = layer(hidden, cos: cosine, sin: sine)
                // Bound lazy vision graphs to one layer, as for Qwen3-VL.
                firebirdPrefillEval([hidden])
            }
            hidden = projector(postLayerNorm(hidden), grid: grid)
            firebirdPrefillEval([hidden])
            return hidden
        }
    }
}

// MARK: - Language

enum PaddleOCRVLLanguage {

    final class Attention: Module {
        let heads: Int
        let kvHeads: Int
        let headDim: Int
        let scale: Float
        let base: Float
        @ModuleInfo(key: "q_proj") var wq: Linear
        @ModuleInfo(key: "k_proj") var wk: Linear
        @ModuleInfo(key: "v_proj") var wv: Linear
        @ModuleInfo(key: "o_proj") var wo: Linear

        init(_ config: PaddleOCRVLConfiguration) {
            heads = config.numAttentionHeads
            kvHeads = config.numKeyValueHeads
            headDim = config.headDim
            scale = pow(Float(headDim), -0.5)
            base = config.ropeTheta
            _wq.wrappedValue = Linear(config.hiddenSize, heads * headDim, bias: false)
            _wk.wrappedValue = Linear(config.hiddenSize, kvHeads * headDim, bias: false)
            _wv.wrappedValue = Linear(config.hiddenSize, kvHeads * headDim, bias: false)
            _wo.wrappedValue = Linear(heads * headDim, config.hiddenSize, bias: false)
        }

        /// `rotary` is the prefill's multimodal `(cos, sin)`. Without it every
        /// position axis is the same text position, so multimodal RoPE reduces
        /// to plain RoPE at `position`.
        func callAsFunction(_ x: MLXArray, rotary: (MLXArray, MLXArray)?, position: Int,
                            cache: KVCache?) -> MLXArray {
            let (batch, length) = (x.dim(0), x.dim(1))
            var queries = wq(x).reshaped(batch, length, heads, headDim).transposed(0, 2, 1, 3)
            var keys = wk(x).reshaped(batch, length, kvHeads, headDim).transposed(0, 2, 1, 3)
            let values = wv(x).reshaped(batch, length, kvHeads, headDim).transposed(0, 2, 1, 3)
            if let (cosine, sine) = rotary {
                queries = queries * cosine + PaddleOCRVLVision.rotateHalf(queries) * sine
                keys = keys * cosine + PaddleOCRVLVision.rotateHalf(keys) * sine
            } else {
                queries = MLXFast.RoPE(queries, dimensions: headDim, traditional: false, base: base, scale: 1, offset: position)
                keys = MLXFast.RoPE(keys, dimensions: headDim, traditional: false, base: base, scale: 1, offset: position)
            }
            let output = attentionWithCacheUpdate(queries: queries, keys: keys, values: values, cache: cache,
                                                  scale: scale, mask: length > 1 ? .causal : .none)
            return wo(output.transposed(0, 2, 1, 3).reshaped(batch, length, -1))
        }
    }

    final class MLP: Module, UnaryLayer {
        @ModuleInfo(key: "gate_proj") var gate: Linear
        @ModuleInfo(key: "up_proj") var up: Linear
        @ModuleInfo(key: "down_proj") var down: Linear

        init(dimensions: Int, hidden: Int) {
            _gate.wrappedValue = Linear(dimensions, hidden, bias: false)
            _up.wrappedValue = Linear(dimensions, hidden, bias: false)
            _down.wrappedValue = Linear(hidden, dimensions, bias: false)
        }

        func callAsFunction(_ x: MLXArray) -> MLXArray { down(silu(gate(x)) * up(x)) }
    }

    final class DecoderLayer: Module {
        @ModuleInfo(key: "self_attn") var attention: Attention
        @ModuleInfo(key: "mlp") var mlp: MLP
        @ModuleInfo(key: "input_layernorm") var inputNorm: RMSNorm
        @ModuleInfo(key: "post_attention_layernorm") var postAttentionNorm: RMSNorm

        init(_ config: PaddleOCRVLConfiguration) {
            _attention.wrappedValue = Attention(config)
            _mlp.wrappedValue = MLP(dimensions: config.hiddenSize, hidden: config.intermediateSize)
            _inputNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
            _postAttentionNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        }

        func callAsFunction(_ x: MLXArray, rotary: (MLXArray, MLXArray)?, position: Int, cache: KVCache?) -> MLXArray {
            let h = x + attention(inputNorm(x), rotary: rotary, position: position, cache: cache)
            return h + mlp(postAttentionNorm(h))
        }
    }

    final class Model: Module {
        @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
        @ModuleInfo(key: "layers") var layers: [DecoderLayer]
        @ModuleInfo(key: "norm") var norm: RMSNorm

        init(_ config: PaddleOCRVLConfiguration) {
            _embedTokens.wrappedValue = Embedding(embeddingCount: config.vocabSize, dimensions: config.hiddenSize)
            _layers.wrappedValue = (0 ..< config.numHiddenLayers).map { _ in DecoderLayer(config) }
            _norm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        }
    }

    final class LanguageModel: Module {
        @ModuleInfo(key: "model") var model: Model
        @ModuleInfo(key: "lm_head") var lmHead: Linear
        let inverseFrequency: [Float]
        let section: [Int]

        init(_ config: PaddleOCRVLConfiguration) {
            _model.wrappedValue = Model(config)
            _lmHead.wrappedValue = Linear(config.hiddenSize, config.vocabSize, bias: false)
            inverseFrequency = paddleInverseFrequencies(dimensions: config.headDim, base: Double(config.ropeTheta))
            section = config.ropeScaling.mropeSection
        }

        /// Multimodal RoPE for `[3, length]` (temporal, row, column) positions:
        /// channel sections of the rotation take their angle from one axis each.
        /// Rounded to the model dtype like the reference; float32 tables (as
        /// `MLXFast.RoPE` computes in decode) flip near ties away from it.
        func rotary(positions: MLXArray, dtype: DType) -> (MLXArray, MLXArray) {
            let angles = positions.asType(.float32)[0..., 0..., .newAxis] * MLXArray(inverseFrequency)
            let doubled = concatenated([angles, angles], axis: -1)
            var bounds = [Int]()
            for size in section + section { bounds.append((bounds.last ?? 0) + size) }
            let chunks = split(doubled, indices: Array(bounds.dropLast()), axis: -1)
            let mixed = concatenated(chunks.enumerated().map { $1[$0 % 3] }, axis: -1)[.newAxis, .newAxis]
            return (cos(mixed).asType(dtype), sin(mixed).asType(dtype))
        }

        func callAsFunction(_ embeddings: MLXArray, rotary: (MLXArray, MLXArray)?, position: Int,
                            cache: [KVCache]?) -> MLXArray {
            var hidden = embeddings
            for (index, layer) in model.layers.enumerated() {
                hidden = layer(hidden, rotary: rotary, position: position, cache: cache?[index])
                if hidden.dim(1) > 1 {
                    firebirdPrefillEval([hidden])
                    if let layerCache = cache?[index] { firebirdPrefillEval(layerCache.state) }
                }
            }
            // Generation consumes only the final position.
            return lmHead(model.norm(hidden[0..., (-1)..., 0...]))
        }
    }
}

// MARK: - Model

public final class PaddleOCRVL: Module, VLMModel, KVCacheDimensionProvider {
    @ModuleInfo(key: "visual") var visual: PaddleOCRVLVision.VisionModel
    @ModuleInfo(key: "language_model") var languageModel: PaddleOCRVLLanguage.LanguageModel

    public let config: PaddleOCRVLConfiguration
    public let kvHeads: [Int]
    /// Decode position minus cache offset: the image occupies fewer positions
    /// than tokens, because its row and column indices share a range.
    private var ropeDelta = 0

    public init(_ config: PaddleOCRVLConfiguration) {
        self.config = config
        kvHeads = Array(repeating: config.numKeyValueHeads, count: config.numHiddenLayers)
        _visual.wrappedValue = PaddleOCRVLVision.VisionModel(config.visionConfig, outputDimensions: config.hiddenSize)
        _languageModel.wrappedValue = PaddleOCRVLLanguage.LanguageModel(config)
    }

    public var loraLayers: [Module] { languageModel.model.layers }

    /// The reference `get_rope_index` for one image: text before it counts up,
    /// image tokens take (start, start + row, start + column), and later text
    /// continues after the largest image position.
    static func positions(tokens: [Int], imageTokenId: Int, grid: THW, mergeSize: Int) -> (MLXArray, Int) {
        let rows = grid.h / mergeSize, columns = grid.w / mergeSize
        let start = tokens.firstIndex(of: imageTokenId) ?? tokens.count
        var t = [Int32](), h = [Int32](), w = [Int32]()
        for index in 0 ..< start { t.append(Int32(index)); h.append(Int32(index)); w.append(Int32(index)) }
        var next = start
        if start < tokens.count {
            for row in 0 ..< rows {
                for column in 0 ..< columns {
                    t.append(Int32(start)); h.append(Int32(start + row)); w.append(Int32(start + column))
                }
            }
            next = start + max(rows, columns)
        }
        for index in 0 ..< (tokens.count - t.count) {
            let value = Int32(next + index)
            t.append(value); h.append(value); w.append(value)
        }
        let last = Int(t.last ?? 0)
        return (MLXArray(t + h + w).reshaped(3, tokens.count), last + 1 - tokens.count)
    }

    public func prepare(_ input: LMInput, cache: [any KVCache], windowSize _: Int?) throws -> PrepareResult {
        guard let image = input.image, let grid = image.frames?.first else { throw VLMError.imageRequired }
        let tokens = input.text.tokens.reshaped(-1).asArray(Int32.self).map(Int.init)
        let textEmbeddings = languageModel.model.embedTokens(input.text.tokens)
        let features = visual(image.pixels, grid: grid)
        // Cancellation skips the remaining prefill evaluations; stop before
        // anything below forces the lazy graph onto the GPU.
        try Task.checkCancellation()
        let imagePositions = MLXArray(tokens.indices.filter { tokens[$0] == config.imageTokenId }.map(Int32.init))
        guard imagePositions.size == features.dim(0) else {
            throw VLMError.processing("Image tokens \(imagePositions.size) do not match features \(features.dim(0))")
        }
        textEmbeddings[0..., imagePositions, 0...] = features.asType(textEmbeddings.dtype).expandedDimensions(axis: 0)
        let (positions, delta) = Self.positions(tokens: tokens, imageTokenId: config.imageTokenId, grid: grid,
                                                mergeSize: config.visionConfig.spatialMergeSize)
        ropeDelta = delta
        let logits = languageModel(textEmbeddings,
            rotary: languageModel.rotary(positions: positions, dtype: textEmbeddings.dtype),
            position: 0, cache: cache)
        try Task.checkCancellation()
        return .logits(LMOutput(logits: logits))
    }

    public func callAsFunction(_ inputs: MLXArray, cache: [any KVCache]?) -> MLXArray {
        languageModel(languageModel.model.embedTokens(inputs), rotary: nil,
                      position: (cache?.first?.offset ?? 0) + ropeDelta, cache: cache)
    }

    /// The pinned mlx-community checkpoint is already in this module layout.
    public func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] { weights }
}
