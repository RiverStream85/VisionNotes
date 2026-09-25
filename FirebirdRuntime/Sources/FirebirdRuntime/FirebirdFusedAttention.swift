import Foundation
import MLX
import MLXLMCommon

/// Single-token decode attention. `.mlx` uses MLX's own SDPA, which works for
/// any head layout and context length. `.fusedExperimental` uses the authored
/// kernel below and stays opt-in until device measurements show a speedup.
public enum FirebirdDecodeAttention: String, Sendable, CaseIterable {
    case mlx
    case fusedExperimental
}

/// Single-token GQA attention specialized for 128-dimensional heads.
/// Cache append and QKV/output projection are separate from this fused dispatch.
enum FirebirdFusedAttention {
    /// Bounded by the kernel's threadgroup score buffer.
    static let maximumContext = 4096

    /// Shapes this kernel implements; anything else falls back to MLX.
    static func supports(heads: Int, kvHeads: Int, headDim: Int, history: Int) -> Bool {
        headDim == 128 && kvHeads > 0 && heads % kvHeads == 0 && history < maximumContext
    }
    private static let kernel: MLXFast.MLXFastKernel = {
        // This is a kernel body wrapped by MLX at runtime, not a standalone Metal source.
        // The .txt suffix keeps Xcode from compiling it as a separate translation unit.
        let url = Bundle.module.url(forResource: "FirebirdAttention", withExtension: "metal.txt", subdirectory: "Kernels")
            ?? Bundle.module.url(forResource: "FirebirdAttention", withExtension: "metal.txt")!
        let source = try! String(contentsOf: url, encoding: .utf8)
        return MLXFast.metalKernel(name: "firebird_qwen3vl_decode",
            inputNames: ["rawQ", "rawK", "rawV", "qWeight", "kWeight", "cosines", "sines", "oldK", "oldV", "shape", "epsilon"],
            outputNames: ["attended", "newK"], source: source)
    }()

    static func call(queries: MLXArray, keys: MLXArray, values: MLXArray,
                     qWeight: MLXArray, kWeight: MLXArray,
                     cos: MLXArray, sin: MLXArray, epsilon: Float,
                     cache: KVCacheSimple) -> MLXArray {
        let heads = queries.dim(1), kvHeads = keys.dim(1), count = cache.offset
        precondition(queries.shape == [1, heads, 1, 128] && keys.shape == [1, kvHeads, 1, 128])
        precondition(heads % kvHeads == 0 && count < maximumContext)
        let history = cache.state
        // Metal requires a bound buffer even when historyLength is zero.
        // The shader never reads this sentinel when count == 0.
        let empty = MLXArray.zeros([1, kvHeads, 1, 128], dtype: keys.dtype)
        let outputs = kernel([
            queries, keys, values, qWeight, kWeight, cos, sin,
            history.first ?? empty, history.last ?? empty,
            MLXArray([Int32(count), Int32(heads), Int32(kvHeads)]), MLXArray([epsilon])
        ], template: [("T", queries.dtype)], grid: (heads * 128, 1, 1), threadGroup: (128, 1, 1),
           outputShapes: [[1, heads, 1, 128], [1, kvHeads, 1, 128]],
           outputDTypes: [queries.dtype, keys.dtype])
        _ = cache.update(keys: outputs[1], values: values)
        return outputs[0]
    }
}

extension FirebirdFusedAttention {
    /// Exercise the kernel on this device's GPU against MLX, without using any
    /// note content. Runs once at load before the fused path is enabled.
    static func validateNumerics() throws {
        for count in [0, 127, 1023] {
            func array(_ shape: [Int], seed: Int) -> MLXArray {
                MLXArray((0..<shape.reduce(1, *)).map {
                    Float((($0 + seed) * 17) % 101 - 50) / 70
                }, shape).asType(.bfloat16)
            }
            let q = array([1, 16, 1, 128], seed: 1)
            let k = array([1, 8, 1, 128], seed: 3)
            let v = array([1, 8, 1, 128], seed: 5)
            let qw = array([128], seed: 7) + 1
            let kw = array([128], seed: 9) + 1
            let c = MLXArray((0..<128).map { cos(Float($0 % 64 + 1) * 0.012) }, [1, 1, 128]).asType(.bfloat16)
            let s = MLXArray((0..<128).map { sin(Float($0 % 64 + 1) * 0.012) }, [1, 1, 128]).asType(.bfloat16)
            let cache = KVCacheSimple()
            let oldK = array([1, 8, count, 128], seed: 11)
            let oldV = array([1, 8, count, 128], seed: 13)
            if count > 0 { cache.state = [oldK, oldV] }
            func rotate(_ x: MLXArray) -> MLXArray {
                x * c + concatenated([-x[.ellipsis, 64...], x[.ellipsis, ..<64]], axis: -1) * s
            }
            let qr = rotate(MLXFast.rmsNorm(q, weight: qw, eps: 1e-6))
            let kr = rotate(MLXFast.rmsNorm(k, weight: kw, eps: 1e-6))
            let reference = MLXFast.scaledDotProductAttention(queries: qr,
                keys: concatenated([oldK, kr], axis: 2),
                values: concatenated([oldV, v], axis: 2),
                scale: 1 / sqrt(Float(128)), mask: .none)
            let fused = call(queries: q, keys: k, values: v, qWeight: qw, kWeight: kw,
                cos: c, sin: s, epsilon: 1e-6, cache: cache)
            eval(reference, fused)
            let difference = max(abs(reference.asType(.float32) - fused.asType(.float32))).item(Float.self)
            let stored = cache.state[0][.ellipsis, count..<(count + 1), 0...]
            let keyDifference = max(abs(stored.asType(.float32) - kr.asType(.float32))).item(Float.self)
            guard difference.isFinite, keyDifference.isFinite,
                  difference < 0.05, keyDifference < 0.05 else {
                throw FirebirdRuntimeError.unsupportedConfiguration
            }
        }
    }
}
