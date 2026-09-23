import XCTest
import Metal
import MLX
import MLXLMCommon
@testable import FirebirdRuntime

final class FusedAttentionTests: XCTestCase {
    func testFusedDecodeMatchesUnfusedAttentionAcrossGQAAndCacheBoundaries() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal GPU required") }
        for dtype in [DType.float32, .float16, .bfloat16] {
            for count in [0, 1, 127, 128, 1023, 4095] {
                try check(count: count, dtype: dtype)
            }
        }
    }

    private func check(count: Int, dtype: DType) throws {
        func array(_ shape: [Int], seed: Int) -> MLXArray {
            let size = shape.reduce(1, *)
            return MLXArray((0..<size).map { Float((($0 + seed) * 17) % 101 - 50) / 70 }, shape).asType(dtype)
        }
        let q = array([1, 16, 1, 128], seed: 1), k = array([1, 8, 1, 128], seed: 3)
        let v = array([1, 8, 1, 128], seed: 5)
        let qw = array([128], seed: 7) + 1, kw = array([128], seed: 9) + 1
        let c = MLXArray((0..<128).map { cos(Float($0 % 64 + 1) * 0.012) }, [1, 1, 128]).asType(dtype)
        let s = MLXArray((0..<128).map { sin(Float($0 % 64 + 1) * 0.012) }, [1, 1, 128]).asType(dtype)
        let cache = KVCacheSimple()
        let oldK = array([1, 8, count, 128], seed: 11), oldV = array([1, 8, count, 128], seed: 13)
        if count > 0 { cache.state = [oldK, oldV] }
        func rotate(_ x: MLXArray) -> MLXArray {
            let half = concatenated([-x[.ellipsis, 64...], x[.ellipsis, ..<64]], axis: -1)
            return x * c + half * s
        }
        let qr = rotate(MLXFast.rmsNorm(q, weight: qw, eps: 1e-6))
        let kr = rotate(MLXFast.rmsNorm(k, weight: kw, eps: 1e-6))
        let keys = concatenated([oldK, kr], axis: 2), values = concatenated([oldV, v], axis: 2)
        let reference = MLXFast.scaledDotProductAttention(queries: qr, keys: keys, values: values,
            scale: 1 / sqrt(Float(128)), mask: .none)
        let fused = FirebirdFusedAttention.call(queries: q, keys: k, values: v,
            qWeight: qw, kWeight: kw, cos: c, sin: s, epsilon: 1e-6, cache: cache)
        eval(reference, fused)
        let difference = max(abs(reference.asType(.float32) - fused.asType(.float32))).item(Float.self)
        XCTAssertLessThan(difference, dtype == .float32 ? 0.0002 : (dtype == .float16 ? 0.025 : 0.05), "history=\(count), dtype=\(dtype)")
        XCTAssertEqual(cache.offset, count + 1)
        let storedKey = cache.state[0][.ellipsis, count..<(count + 1), 0...]
        let keyDifference = max(abs(storedKey.asType(.float32) - kr.asType(.float32))).item(Float.self)
        XCTAssertLessThan(keyDifference, dtype == .float32 ? 0.0002 : (dtype == .float16 ? 0.025 : 0.05))
    }
}
