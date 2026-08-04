import CoreGraphics
import Foundation

/// Result of running OCR over one page image.
struct RecognizedPage: Sendable {
    let blocks: [RecognizedTextBlock]
    let text: String

    static let empty = RecognizedPage(blocks: [], text: "")
}

/// Decode → downscale → recognize → order → compose, in one place.
///
/// Every method is `nonisolated async`, so callers on the main actor hand the
/// work to the cooperative thread pool instead of running it themselves. Input
/// and output are `Sendable` values (`Data`, structs), which keeps the images
/// from being shared across tasks.
struct OCRPipeline: Sendable {
    let recognizer: TextRecognitionService
    let sorter: ReadingOrderSorter
    let languages: [String]

    init(
        recognizer: TextRecognitionService = AppleVisionTextRecognitionService(),
        sorter: ReadingOrderSorter = ReadingOrderSorter(),
        languages: [String] = ["en-US", "zh-Hans"]
    ) {
        self.recognizer = recognizer
        self.sorter = sorter
        self.languages = languages
    }

    /// Runs OCR over encoded image data (JPEG/PNG/HEIC).
    func recognizePage(fromImageData data: Data) async throws -> RecognizedPage {
        try Task.checkCancellation()
        let image = try ImageProcessor.uprightImage(from: data)
        let cgImage = try ImageProcessor.cgImage(from: image)
        let downscaled = ImageProcessor.downscaled(cgImage, longEdge: ImageProcessor.ocrLongEdge)
        return try await recognizePage(from: downscaled)
    }

    func recognizePage(from image: CGImage) async throws -> RecognizedPage {
        let blocks = try await recognizer.recognizeText(in: image, languages: languages)
        let ordered = sorter.ordered(blocks)
        let text = PageTextComposer.composeText(from: ordered, sorter: sorter)
        return RecognizedPage(blocks: ordered, text: text)
    }
}
