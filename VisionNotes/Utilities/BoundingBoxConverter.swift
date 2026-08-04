import CoreGraphics
import Foundation

/// Converts between Vision's normalized coordinate space (origin bottom-left,
/// 0...1 on both axes) and the top-left origin space SwiftUI draws in.
enum BoundingBoxConverter {

    /// Maps a Vision rect onto an image of `imageSize`, flipping the Y axis.
    static func imageRect(fromNormalized normalized: CGRect, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let width = normalized.width * imageSize.width
        let height = normalized.height * imageSize.height
        let x = normalized.origin.x * imageSize.width
        // Vision measures Y from the bottom; SwiftUI measures it from the top.
        let y = (1 - normalized.origin.y - normalized.height) * imageSize.height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Inverse of `imageRect(fromNormalized:imageSize:)`.
    static func normalizedRect(fromImageRect rect: CGRect, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let width = rect.width / imageSize.width
        let height = rect.height / imageSize.height
        let x = rect.origin.x / imageSize.width
        let y = 1 - (rect.origin.y / imageSize.height) - height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The frame an image occupies inside `containerSize` under `.scaledToFit`.
    static func fittedImageFrame(imageSize: CGSize, containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else { return .zero }
        let scale = min(
            containerSize.width / imageSize.width,
            containerSize.height / imageSize.height
        )
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(
            x: (containerSize.width - size.width) / 2,
            y: (containerSize.height - size.height) / 2
        )
        return CGRect(origin: origin, size: size)
    }

    /// Maps a Vision rect straight into the coordinates of a `.scaledToFit`
    /// image displayed inside `containerSize`. This is what the overlay uses.
    static func displayRect(
        normalized: CGRect,
        imageSize: CGSize,
        containerSize: CGSize
    ) -> CGRect {
        let frame = fittedImageFrame(imageSize: imageSize, containerSize: containerSize)
        guard frame.width > 0, frame.height > 0 else { return .zero }
        let inImage = imageRect(fromNormalized: normalized, imageSize: frame.size)
        return inImage.offsetBy(dx: frame.origin.x, dy: frame.origin.y)
    }
}
