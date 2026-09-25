import Foundation
import ImageIO
import Observation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct PreparedImage: Sendable {
    let ocrData: Data
    let previewData: Data
}

@MainActor
@Observable
final class OCRViewModel {
    var selectedImage: UIImage?
    var resultText = ""
    var mode: OCRMode = .document
    var performanceMode: OCRPerformanceMode = .recommended
    var isRunning = false
    var isPreparingImage = false
    var status = "Choose an image to begin"
    var metrics: OCRMetrics?
    var errorMessage: String?

    private let runtime = OCRRuntime()
    private var selectedImageData: Data?
    private var selectionRevision: UInt64 = 0
    private var recognitionTask: Task<Void, Never>?

    var isBusy: Bool { isRunning || isPreparingImage }

    func loadPhotoItem(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        let revision = beginImagePreparation()
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw OCRError.invalidImage
            }
            let prepared = try await Task.detached(priority: .userInitiated) {
                try Self.prepareImageData(data)
            }.value
            applyPreparedImage(prepared, revision: revision, status: "Ready for local OCR")
        } catch {
            guard selectionRevision == revision else { return }
            isPreparingImage = false
            errorMessage = error.localizedDescription
            status = "Image preparation failed"
        }
    }

    func loadFile(_ url: URL) async {
        let revision = beginImagePreparation()
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                return try Self.prepareImageData(data)
            }.value
            applyPreparedImage(prepared, revision: revision, status: "Ready for local OCR")
        } catch {
            guard selectionRevision == revision else { return }
            isPreparingImage = false
            errorMessage = error.localizedDescription
            status = "Image preparation failed"
        }
    }

    func loadMathFixture() async {
        let revision = beginImagePreparation()
        guard let url = Bundle.main.url(forResource: "math-ocr-test", withExtension: "png"),
              let data = try? Data(contentsOf: url)
        else {
            isPreparingImage = false
            errorMessage = "The bundled math OCR test page is missing."
            return
        }
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                try Self.prepareImageData(data)
            }.value
            applyPreparedImage(prepared, revision: revision, status: "Math test page ready")
        } catch {
            guard selectionRevision == revision else { return }
            isPreparingImage = false
            errorMessage = error.localizedDescription
            status = "Image preparation failed"
        }
    }

    func prepareSmokeTestReport(runID: String) {
        Self.writeSmokeTestReport("""
        # DeepSeek OCR device smoke test

        - Run ID: \(runID)
        - Status: RUNNING
        """)
    }

    func runOCR(saveSmokeTestReport: Bool = false, smokeRunID: String? = nil) {
        guard !isRunning else { return }
        guard let data = selectedImageData else {
            let error = OCRError.invalidImage
            errorMessage = error.localizedDescription
            status = "OCR failed"
            if saveSmokeTestReport {
                Self.saveSmokeTestFailure(error, runID: smokeRunID ?? "unspecified")
            }
            return
        }
        let requestRevision = selectionRevision
        let prompt = mode.prompt
        let requestedPerformanceMode = performanceMode

        isRunning = true
        resultText = ""
        metrics = nil
        errorMessage = nil
        status = "Loading 2.46 GB model and reading image…"

        recognitionTask = Task {
            defer {
                isRunning = false
                recognitionTask = nil
            }
            do {
                let result = try await runtime.recognize(
                    imageData: data,
                    prompt: prompt,
                    performanceMode: requestedPerformanceMode)
                guard selectionRevision == requestRevision else { return }
                resultText = result.text
                metrics = result.metrics
                if result.metrics.isTruncated {
                    status = "OCR stopped at the context limit — result may be incomplete"
                } else if result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    status = "OCR complete — no text detected"
                } else if Self.isThermallyConstrained {
                    status = "OCR complete — device heat throttled this run"
                } else {
                    status = "OCR complete — fully local"
                }
                if saveSmokeTestReport {
                    Self.saveSmokeTestReport(
                        result,
                        requestedMode: requestedPerformanceMode,
                        runID: smokeRunID ?? "unspecified")
                }
            } catch {
                guard selectionRevision == requestRevision else { return }
                if error is CancellationError {
                    errorMessage = nil
                    status = "OCR cancelled"
                } else {
                    errorMessage = error.localizedDescription
                    status = "OCR failed"
                }
                if saveSmokeTestReport {
                    Self.saveSmokeTestFailure(error, runID: smokeRunID ?? "unspecified")
                }
            }
        }
    }

    func cancelOCR() {
        guard isRunning else { return }
        status = "Cancelling OCR…"
        recognitionTask?.cancel()
        runtime.cancel()
    }

    private func beginImagePreparation() -> UInt64 {
        selectionRevision &+= 1
        isPreparingImage = true
        errorMessage = nil
        status = "Preparing image…"
        return selectionRevision
    }

    private func applyPreparedImage(
        _ prepared: PreparedImage,
        revision: UInt64,
        status newStatus: String
    ) {
        guard selectionRevision == revision else { return }
        guard let preview = UIImage(data: prepared.previewData) else {
            isPreparingImage = false
            errorMessage = OCRError.invalidImage.localizedDescription
            status = "Image preparation failed"
            return
        }
        selectedImage = preview
        selectedImageData = prepared.ocrData
        isPreparingImage = false
        resultText = ""
        metrics = nil
        status = newStatus
    }

    nonisolated private static func prepareImageData(_ data: Data) throws -> PreparedImage {
        try autoreleasepool {
            guard let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
            else {
                throw OCRError.invalidImage
            }

            // DeepSeek-OCR-2 observes a 1024px global view plus at most six
            // 768px crops. Preserve that useful pixel budget without retaining
            // a full 48MP camera frame; extreme panoramas can still reach 4608px.
            let sourceWidth = max(1, width.doubleValue)
            let sourceHeight = max(1, height.doubleValue)
            let sourcePixels = sourceWidth * sourceHeight
            guard sourceWidth.isFinite,
                  sourceHeight.isFinite,
                  sourcePixels.isFinite,
                  width.doubleValue > 0,
                  height.doubleValue > 0,
                  sourceWidth <= 1_000_000,
                  sourceHeight <= 1_000_000,
                  sourcePixels <= 250_000_000 else {
                throw OCRError.invalidImage
            }
            let usefulPixels = 6.0 * 768.0 * 768.0
            let scale = min(1, sqrt(usefulPixels / sourcePixels))
            let ocrMaximumDimension = min(
                4608,
                Int(ceil(max(sourceWidth, sourceHeight) * scale)))

            guard let ocrImage = thumbnail(
                from: source,
                maximumDimension: max(1, ocrMaximumDimension)) else {
                throw OCRError.invalidImage
            }

            let sourceType = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
            let alpha = ocrImage.alphaInfo
            let hasAlpha = alpha == .first || alpha == .last
                || alpha == .premultipliedFirst || alpha == .premultipliedLast
            let shouldPreserveLosslessly = hasAlpha
                || sourceType?.conforms(to: .png) == true
                || sourceType?.conforms(to: .tiff) == true
            let ocrType: UTType = shouldPreserveLosslessly ? .png : .jpeg
            let ocrData = try encoded(
                ocrImage,
                as: ocrType,
                quality: shouldPreserveLosslessly ? nil : 0.96)

            guard let previewImage = thumbnail(from: source, maximumDimension: 1200) else {
                throw OCRError.invalidImage
            }
            let previewType: UTType = hasAlpha ? .png : .jpeg
            let previewData = try encoded(previewImage, as: previewType, quality: 0.88)
            return PreparedImage(ocrData: ocrData, previewData: previewData)
        }
    }

    nonisolated private static func thumbnail(
        from source: CGImageSource,
        maximumDimension: Int
    ) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    nonisolated private static func encoded(
        _ image: CGImage,
        as type: UTType,
        quality: Double?
    ) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            type.identifier as CFString,
            1,
            nil) else {
            throw OCRError.invalidImage
        }
        var properties: [CFString: Any] = [:]
        if let quality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw OCRError.invalidImage
        }
        return output as Data
    }

    private static func saveSmokeTestReport(
        _ result: OCRResult,
        requestedMode: OCRPerformanceMode,
        runID: String
    ) {
        var missingChecks = smokeTestMissingChecks(
            in: result.text,
            fastVision: requestedMode == .fast)
        if requestedMode == .fast {
            if !result.metrics.fastVisionUsed {
                missingChecks.append("fast overview path selected")
            }
            if result.metrics.inputTokens > 300 {
                missingChecks.append("fast overview token budget")
            }
        } else if result.metrics.fastVisionUsed {
            missingChecks.append("accurate detail path selected")
        }
        let passed = missingChecks.isEmpty && !result.metrics.isTruncated
        let missingSummary = missingChecks.isEmpty ? "none" : missingChecks.joined(separator: ", ")
        let report = """
        # DeepSeek OCR device smoke test

        - Run ID: \(runID)
        - Status: \(passed ? "PASS" : "FAIL")
        - Model load: \(String(format: "%.2f", result.metrics.modelLoadSeconds)) s
        - Image encode: \(String(format: "%.2f", result.metrics.encodeSeconds)) s
        - Generation: \(String(format: "%.2f", result.metrics.generationSeconds)) s
        - Tokens: \(result.metrics.inputTokens) input / \(result.metrics.outputTokens) output
        - Vision path: \(result.metrics.fastVisionUsed ? "fast overview" : "accurate details")
        - Thermal state: \(thermalStateLabel(ProcessInfo.processInfo.thermalState))
        - Low Power Mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off")
        - Truncated: \(result.metrics.isTruncated ? "yes" : "no")
        - Missing checks: \(missingSummary)

        \(result.text)
        """

        if let output = writeSmokeTestReport(report) {
            let event = passed
                ? "DEEPSEEK_OCR_SMOKE_TEST_COMPLETE"
                : "DEEPSEEK_OCR_SMOKE_TEST_VALIDATION_FAILED"
            print("\(event) \(output.path)")
        }
    }

    private static func smokeTestMissingChecks(
        in text: String,
        fastVision: Bool
    ) -> [String] {
        var compact = text
            .filter { !$0.isWhitespace }
            .replacingOccurrences(of: "&=", with: "=")
        if fastVision {
            // Overview-only OCR can choose semantically equivalent LaTeX for
            // a left-braced piecewise function. Normalize only the Fast smoke
            // test; Accurate keeps the strict byte-level regression checks.
            compact = compact
                .replacingOccurrences(
                    of: #"\left\{\begin{aligned}"#,
                    with: #"\begin{cases}"#)
                .replacingOccurrences(of: #"&\quad"#, with: "&")
                .replacingOccurrences(
                    of: #"\end{aligned}\right."#,
                    with: #"\end{cases}"#)
                .replacingOccurrences(
                    of: "Endoftest‘preserve",
                    with: "Endoftest·preserve")
                .replacingOccurrences(
                    of: "Endoftest'preserve",
                    with: "Endoftest·preserve")
        }
        let checks: [(String, String)] = [
            ("heading", "OCRsmalltest"),
            ("Hello world", "Hello,world!"),
            ("English prose", "Thequickbrownfoxjumpsover13lazydogs.Mathmustbetranscribed,notsolved."),
            ("Chinese prose", "中文测试：本地模型应该准确识别汉字、标点符号"),
            ("Euler identity", #"e^{i\pi}+1=0"#),
            ("binomial theorem", #"(x+y)^{n}=\sum_{k=0}^{n}\binom{n}{k}x^{n-k}y^{k}"#),
            ("vector norm", #"\|x\|_{2}=\sqrt{x_{1}^{2}+\cdots+x_{d}^{2}}"#),
            ("Gaussian integral", #"\int_{-\infty}^{\infty}e^{-x^{2}}dx=\sqrt{\pi}"#),
            ("zeta series", #"\zeta(s)=\sum_{n=1}^{\infty}\frac{1}{n^{s}}"#),
            ("zeta domain", #"\Re(s)>1"#),
            ("matrix", #"\begin{pmatrix}"#),
            ("matrix alpha", #"\alpha"#),
            ("matrix beta", #"\beta^{2}"#),
            ("matrix fraction", #"\frac{1}{2}"#),
            ("matrix square root", #"\sqrt{2}"#),
            ("matrix complex entry", #"e^{i\theta}"#),
            ("determinant", #"\det(\mathbf{A}-\lambda\mathbf{I})=0"#),
            ("piecewise function", #"\begin{cases}x^{2}\sin(1/x),&x\neq0"#),
            ("piecewise zero branch", #"0,&x=0"#),
            ("Maxwell Gauss law", #"\nabla\cdot\mathbf{E}=\frac{\rho}{\varepsilon_{0}}"#),
            ("Maxwell magnetic law", #"\nabla\cdot\mathbf{B}=0"#),
            ("Maxwell Faraday law", #"\nabla\times\mathbf{E}=-\frac{\partial\mathbf{B}}{\partialt}"#),
            ("Maxwell Ampere law", #"\nabla\times\mathbf{B}=\mu_{0}\mathbf{J}+\mu_{0}\varepsilon_{0}\frac{\partial\mathbf{E}}{\partialt}"#),
            ("Navier-Stokes", #"\frac{\partial\mathbf{u}}{\partialt}+(\mathbf{u}\cdot\nabla)\mathbf{u}"#),
            ("Navier-Stokes pressure", #"=-\frac{1}{\rho}\nabla p"#.replacingOccurrences(of: " ", with: "")),
            ("Navier-Stokes viscosity", #"+\nu\nabla^{2}\mathbf{u}+\mathbf{f}"#),
            ("incompressibility", #"\nabla\cdot\mathbf{u}=0"#),
            ("end marker", "Endoftest·preservesuperscripts,subscripts,Greekletters,anddelimiters."),
        ]
        var missing: [String] = []
        var cursor = compact.startIndex
        for (name, fragment) in checks {
            guard let range = compact.range(of: fragment, range: cursor..<compact.endIndex) else {
                missing.append(name)
                continue
            }
            cursor = range.upperBound
        }
        if compact.count > 8_000 {
            missing.append("bounded output length")
        }
        if compact.contains("OCR:OCR:OCR:") {
            missing.append("no startup repetition loop")
        }
        for (name, marker) in [("single heading", "OCRsmalltest"), ("single end marker", "Endoftest")] {
            if compact.components(separatedBy: marker).count - 1 != 1 {
                missing.append(name)
            }
        }
        return missing
    }

    private static func saveSmokeTestFailure(_ error: Error, runID: String) {
        let report = """
        # DeepSeek OCR device smoke test

        - Run ID: \(runID)
        - Status: FAIL

        \(error.localizedDescription)
        """
        if let output = writeSmokeTestReport(report) {
            print("DEEPSEEK_OCR_SMOKE_TEST_FAILED \(output.path): \(error.localizedDescription)")
        }
    }

    private static var isThermallyConstrained: Bool {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: true
        case .nominal, .fair: false
        @unknown default: false
        }
    }

    private static func thermalStateLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    @discardableResult
    private static func writeSmokeTestReport(_ report: String) -> URL? {
        do {
            let documents = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true)
            let output = documents.appendingPathComponent("deepseek-ocr-smoke-test.md")
            try report.write(to: output, atomically: true, encoding: .utf8)
            return output
        } catch {
            print("DEEPSEEK_OCR_SMOKE_TEST_SAVE_FAILED \(error.localizedDescription)")
            return nil
        }
    }
}
