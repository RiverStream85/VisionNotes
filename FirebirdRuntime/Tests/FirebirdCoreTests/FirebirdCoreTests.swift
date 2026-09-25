import XCTest
@testable import FirebirdCore

final class RepetitionLoopDetectorTests: XCTestCase {
    private let detector = RepetitionLoopDetector()

    func testDetectsRunawayRepeatedBlock() {
        let text = "# Notes\n$$a=b$$\n" + String(repeating: "\\frac{1}{2} + ", count: 40)
        XCTAssertEqual(detector.period(in: text), "\\frac{1}{2} + ".unicodeScalars.count)
    }

    func testDetectsRepeatedLines() {
        let line = "The derivative of $x^2$ is $2x$.\n"
        XCTAssertNotNil(detector.period(in: "Intro\n" + String(repeating: line, count: 12)))
    }

    func testIgnoresShortLegitimateRepetition() {
        let zeroMatrix = "$$\\begin{pmatrix}" + String(repeating: "0 & 0 & 0 \\\\ ", count: 6) + "\\end{pmatrix}$$"
        XCTAssertNil(detector.period(in: zeroMatrix))
        XCTAssertNil(detector.period(in: "$$x_1 + x_2 + x_3 = y_1 + y_2 + y_3$$"))
    }

    func testIgnoresOrdinaryProse() {
        let text = """
            # Linear maps
            Let $T: V \\to W$ be linear. Then $\\ker T$ is a subspace of $V$ and $\\operatorname{im} T$ is a subspace of $W$.
            By rank–nullity, $\\dim V = \\dim \\ker T + \\dim \\operatorname{im} T$. For a matrix $A \\in \\mathbb{R}^{m \\times n}$,
            the column space has dimension $\\operatorname{rank} A$ and $A x = b$ is solvable exactly when $b$ lies in it.
            """
        XCTAssertNil(detector.period(in: text))
    }

    func testTrimmingKeepsOneCopyOfLoop() {
        let block = "\\sum_{i=1}^{n} a_i + "
        let text = "# Notes\n" + String(repeating: block, count: 20)
        XCTAssertEqual(detector.trimmingLoop(text), "# Notes\n" + block)
        XCTAssertEqual(detector.trimmingLoop("no loop here"), "no loop here")
    }

    func testRequiresEnoughText() {
        XCTAssertNil(detector.period(in: String(repeating: "ab", count: 50)))
        XCTAssertEqual(detector.period(in: String(repeating: "ab", count: 200)), 2)
    }
}

final class FirebirdDeviceBudgetTests: XCTestCase {
    // Pinned Qwen3-VL-2B 4-bit: 28 layers, 8 KV heads, 128-dim heads, 16-bit cache.
    private let footprint = FirebirdModelFootprint(weightBytes: 1_782_040_921, layers: 28, kvHeads: 8, headDim: 128)
    private let gib = 1_073_741_824

    func testKVBytesPerToken() {
        XCTAssertEqual(footprint.kvBytesPerToken, 114_688)
    }

    func testTierGrowsWithAvailableMemory() {
        XCTAssertNil(FirebirdDeviceBudget.select(footprint: footprint, available: 3 * gib))
        let tiers = [3.1, 3.3, 3.5, 10].map {
            FirebirdDeviceBudget.select(footprint: footprint, available: Int($0 * Double(gib)), ceiling: .high)?.tier
        }
        XCTAssertEqual(tiers, [.reduced, .standard, .extended, .high])
    }

    func testDefaultCeilingIsMeasuredTier() {
        XCTAssertEqual(FirebirdDeviceBudget.select(footprint: footprint, available: 10 * gib)?.tier, .extended)
    }

    func testCeilingCapsTier() {
        let budget = FirebirdDeviceBudget.select(footprint: footprint, available: 16 * gib, ceiling: .standard)
        XCTAssertEqual(budget?.tier, .standard)
        XCTAssertEqual(budget?.maxPixels, 524_288)
        XCTAssertEqual(budget?.maxContext, 4_096)
    }

    func testLimitsStayWithinAvailableMemory() throws {
        for available in stride(from: 4 * gib, through: 12 * gib, by: gib / 2) {
            let budget = try XCTUnwrap(FirebirdDeviceBudget.select(footprint: footprint, available: available))
            XCTAssertLessThanOrEqual(budget.memoryLimit, available)
            XCTAssertGreaterThanOrEqual(budget.memoryLimit, footprint.weightBytes + budget.pageHeadroom)
            XCTAssertLessThanOrEqual(budget.cacheLimit, 256 * 1_048_576)
            XCTAssertGreaterThanOrEqual(budget.cacheLimit, 32 * 1_048_576)
            // Room for the image tokens, the prompt and a useful answer.
            XCTAssertGreaterThan(budget.maxContext - budget.maxPixels / 1_024, 2_000)
        }
    }
}

final class FirebirdRecipeTests: XCTestCase {
    func testDefaultRecipeIsDeterministicFirst() {
        let recipe = FirebirdRecipe.academicTranscription
        XCTAssertEqual(recipe.attempts.first, .greedy)
        XCTAssertTrue(recipe.attempts.allSatisfy { $0.temperature == 0 })
    }

    func testIdentityDerivesCheckpointPath() {
        let identity = FirebirdModelIdentity(repository: "mlx-community/Qwen3-VL-2B-Instruct-4bit",
            revision: "9c4f5209e57b31f4b9dfba735de3fb983739c9cc", recipeVersion: "recipe-3")
        XCTAssertEqual(identity.identifier, "mlx-community/Qwen3-VL-2B-Instruct-4bit@9c4f5209e57b31f4b9dfba735de3fb983739c9cc/recipe-3")
        XCTAssertEqual(identity.checkpointPath(pageIndex: 0), "firebird-qwen3-vl-2b-instruct-4bit-9c4f5209-recipe-3-page-001.json")
    }
}

final class TranscriptionMetricsTests: XCTestCase {
    func testDelimiterAndWhitespaceDoNotCount() {
        XCTAssertEqual(TranscriptionMetrics.characterErrorRate(prediction: "$$ a + b $$", reference: "\\(a+b\\)"), 0)
    }

    func testEditDistance() {
        XCTAssertEqual(TranscriptionMetrics.editDistance("kitten", "sitting"), 3)
        XCTAssertEqual(TranscriptionMetrics.editDistance("", "abc"), 3)
        XCTAssertEqual(TranscriptionMetrics.characterErrorRate(prediction: "x_1", reference: "x_2"), 1.0 / 3.0, accuracy: 1e-9)
    }
}
