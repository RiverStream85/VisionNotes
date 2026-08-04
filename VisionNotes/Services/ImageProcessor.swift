import CoreGraphics
import Foundation
import UIKit

/// Image helpers shared by the import pipeline: orientation normalisation,
/// downscaling for OCR, JPEG encoding and thumbnails.
///
/// All of it is pure Core Graphics / UIKit work with no UI dependency, so it is
/// safe to call from a background task.
enum ImageProcessor {
    /// Long edge used when handing an image to Vision. Large enough for small
    /// print, small enough to keep memory per page modest.
    static let ocrLongEdge: CGFloat = 2000
    /// Long edge of the cached page image kept for the readers.
    static let pageCacheLongEdge: CGFloat = 1400
    static let thumbnailLongEdge: CGFloat = 320

    /// Decodes image data and redraws it upright, because Vision's normalized
    /// coordinates only line up with what the user sees when the pixels are
    /// already in `.up` orientation.
    static func uprightImage(from data: Data) throws -> UIImage {
        guard let image = UIImage(data: data) else {
            throw AppError.unsupportedImageFormat
        }
        return upright(image)
    }

    static func upright(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    static func cgImage(from image: UIImage) throws -> CGImage {
        if let cgImage = image.cgImage { return cgImage }
        // A CIImage-backed UIImage (rare, e.g. some filters) needs a redraw.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let redrawn = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard let cgImage = redrawn.cgImage else { throw AppError.unsupportedImageFormat }
        return cgImage
    }

    /// Scales an image down so its long edge is at most `longEdge`.
    /// Images that are already small enough are returned unchanged.
    static func downscaled(_ image: CGImage, longEdge: CGFloat) -> CGImage {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let currentLongEdge = max(width, height)
        guard currentLongEdge > longEdge, currentLongEdge > 0 else { return image }

        let scale = longEdge / currentLongEdge
        let targetSize = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let scaled = renderer.image { _ in
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return scaled.cgImage ?? image
    }

    static func jpegData(from image: CGImage, quality: CGFloat = 0.8) throws -> Data {
        guard let data = UIImage(cgImage: image).jpegData(compressionQuality: quality) else {
            throw AppError.fileWriteFailed(reason: "The image could not be encoded as JPEG.")
        }
        return data
    }

    static func thumbnailData(from image: CGImage, longEdge: CGFloat = thumbnailLongEdge) throws -> Data {
        try jpegData(from: downscaled(image, longEdge: longEdge), quality: 0.7)
    }

    static func size(of image: CGImage) -> CGSize {
        CGSize(width: image.width, height: image.height)
    }
}
