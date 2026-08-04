import CoreGraphics
import Foundation
import UIKit

/// An imported image, normalised and encoded ready to be written to disk.
struct PreparedImage: Sendable {
    /// Upright JPEG that becomes the stored original.
    let sourceData: Data
    let thumbnailData: Data
    let pixelSize: CGSize
}

/// Off-main-actor image preparation for the import pipeline.
enum ImagePreparer {

    /// Decodes, uprights, and re-encodes an imported image, plus a thumbnail.
    /// `nonisolated async` on purpose: called from `@MainActor` code, it runs
    /// on the cooperative pool instead of blocking the UI.
    static func prepare(_ data: Data) async throws -> PreparedImage {
        try Task.checkCancellation()
        let image = try ImageProcessor.uprightImage(from: data)
        let cgImage = try ImageProcessor.cgImage(from: image)
        let sourceData = try ImageProcessor.jpegData(from: cgImage, quality: 0.9)
        let thumbnailData = try ImageProcessor.thumbnailData(from: cgImage)
        return PreparedImage(
            sourceData: sourceData,
            thumbnailData: thumbnailData,
            pixelSize: ImageProcessor.size(of: cgImage)
        )
    }

    /// Encodes a captured image as an upright JPEG, off the main actor.
    static func encodeJPEG(from image: UIImage, quality: CGFloat = 0.9) async throws -> Data {
        try Task.checkCancellation()
        let upright = ImageProcessor.upright(image)
        guard let data = upright.jpegData(compressionQuality: quality) else {
            throw AppError.photoLoadFailed
        }
        return data
    }

    /// Builds just a thumbnail from encoded image data.
    static func thumbnail(from data: Data) async throws -> Data {
        try Task.checkCancellation()
        let image = try ImageProcessor.uprightImage(from: data)
        let cgImage = try ImageProcessor.cgImage(from: image)
        return try ImageProcessor.thumbnailData(from: cgImage)
    }
}
