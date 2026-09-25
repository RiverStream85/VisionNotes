import Foundation

/// Memory facts about the loaded checkpoint, read from its config and files.
public struct FirebirdModelFootprint: Equatable, Sendable {
    public let weightBytes: Int
    /// Keys plus values for one token across every language-model layer.
    public let kvBytesPerToken: Int

    public init(weightBytes: Int, kvBytesPerToken: Int) {
        self.weightBytes = weightBytes; self.kvBytesPerToken = kvBytesPerToken
    }

    public init(weightBytes: Int, layers: Int, kvHeads: Int, headDim: Int, bytesPerElement: Int = 2) {
        self.init(weightBytes: weightBytes, kvBytesPerToken: 2 * layers * kvHeads * headDim * bytesPerElement)
    }
}

/// Resolution and context limits for one device, chosen from the memory the
/// process may actually use rather than from a device model name.
public struct FirebirdDeviceBudget: Equatable, Sendable {
    public let tier: Tier
    public let maxPixels: Int
    public let maxContext: Int
    /// Upper bound handed to MLX; allocations above it wait for scheduled work.
    public let memoryLimit: Int
    /// Reusable buffer pool. Too small reallocates every decode step.
    public let cacheLimit: Int
    /// Free memory required before each page starts, excluding the weights.
    public let pageHeadroom: Int

    public enum Tier: String, CaseIterable, Sendable, Comparable {
        case reduced, standard, extended, high

        public static func < (lhs: Tier, rhs: Tier) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }

        /// Qwen3-VL uses 16-pixel patches merged 2×2, so one visual token is
        /// 32×32 = 1,024 pixels. Context must cover the image, prompt and output.
        var maxPixels: Int {
            switch self {
            case .reduced: 393_216
            case .standard: 524_288
            case .extended: 786_432
            case .high: 1_048_576
            }
        }

        var maxContext: Int {
            switch self {
            case .reduced: 3_072
            case .standard: 4_096
            case .extended: 5_120
            case .high: 6_144
            }
        }
    }

    static let mebibyte = 1_048_576
    /// Uncalibrated reserve for vision/prefill activations and framework state.
    /// Replace with measured per-device peaks from the evaluation harness.
    static let fixedReserve = 384 * mebibyte
    static let reservePerPixel = 512
    /// Kept free for UIKit, the tokenizer and allocator fragmentation.
    static let safetyMargin = 512 * mebibyte

    public init(tier: Tier, footprint: FirebirdModelFootprint, available: Int) {
        let transient = Self.transientBytes(tier: tier, footprint: footprint)
        let required = footprint.weightBytes + transient
        self.tier = tier
        maxPixels = tier.maxPixels
        maxContext = tier.maxContext
        pageHeadroom = transient
        memoryLimit = max(required, available - Self.safetyMargin)
        // Spare room beyond the requirement becomes buffer cache, bounded so
        // it cannot crowd out the rest of the app.
        let spare = max(0, available - Self.safetyMargin - required)
        cacheLimit = min(256 * Self.mebibyte, max(32 * Self.mebibyte, spare / 2))
    }

    static func transientBytes(tier: Tier, footprint: FirebirdModelFootprint) -> Int {
        footprint.kvBytesPerToken * tier.maxContext + fixedReserve + reservePerPixel * tier.maxPixels
    }

    /// Latency and memory of `.high` have not been measured on a phone yet.
    public static let defaultCeiling = Tier.extended

    /// The largest tier that fits, or nil when even the reduced tier would
    /// risk a memory termination. `available` is measured before weights load.
    public static func select(footprint: FirebirdModelFootprint, available: Int,
                              ceiling: Tier = defaultCeiling) -> FirebirdDeviceBudget? {
        Tier.allCases.reversed().filter { $0 <= ceiling }.lazy.compactMap { tier in
            let required = footprint.weightBytes + transientBytes(tier: tier, footprint: footprint) + safetyMargin
            return required <= available ? FirebirdDeviceBudget(tier: tier, footprint: footprint, available: available) : nil
        }.first
    }
}
