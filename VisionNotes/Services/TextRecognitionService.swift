import CoreGraphics
import Foundation
import Vision

/// On-device text recognition. Implementations must never touch the main actor.
protocol TextRecognitionService: Sendable {
    func recognizeText(
        in image: CGImage,
        languages: [String]
    ) async throws -> [RecognizedTextBlock]
}

extension TextRecognitionService {
    /// The languages the app recognizes by default: English and Simplified Chinese.
    static var defaultLanguages: [String] { ["en-US", "zh-Hans"] }

    func recognizeText(in image: CGImage) async throws -> [RecognizedTextBlock] {
        try await recognizeText(in: image, languages: Self.defaultLanguages)
    }
}

/// Apple Vision implementation. Runs `VNRecognizeTextRequest` on a private
/// queue so the (synchronous, potentially slow) request never blocks the UI.
final class AppleVisionTextRecognitionService: TextRecognitionService {

    private let queue = DispatchQueue(
        label: "com.visionnotes.ocr",
        qos: .userInitiated
    )

    func recognizeText(
        in image: CGImage,
        languages: [String] = AppleVisionTextRecognitionService.defaultLanguages
    ) async throws -> [RecognizedTextBlock] {
        try Task.checkCancellation()

        let blocks: [RecognizedTextBlock] = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let recognized = try Self.performRequest(image: image, languages: languages)
                    continuation.resume(returning: recognized)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        try Task.checkCancellation()
        return blocks
    }

    // MARK: - Private

    private static func performRequest(
        image: CGImage,
        languages: [String]
    ) throws -> [RecognizedTextBlock] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = supportedLanguages(from: languages)

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw AppError.ocrRequestFailed(reason: error.localizedDescription)
        }

        let observations = request.results ?? []
        return observations.enumerated().compactMap { index, observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return RecognizedTextBlock(
                text: text,
                confidence: candidate.confidence,
                boundingBox: observation.boundingBox,
                readingOrder: index
            )
        }
    }

    /// Vision throws if it is handed a language it cannot recognize, so the
    /// requested list is intersected with what this device actually supports.
    private static func supportedLanguages(from requested: [String]) -> [String] {
        let probe = VNRecognizeTextRequest()
        probe.recognitionLevel = .accurate
        let supported = (try? probe.supportedRecognitionLanguages()) ?? []
        guard !supported.isEmpty else { return requested }

        let filtered = requested.filter { supported.contains($0) }
        if !filtered.isEmpty { return filtered }
        // Nothing requested is available here; fall back to the first language
        // this device does support rather than failing the whole request.
        return supported.prefix(1).map { $0 }
    }
}
