@preconcurrency import CoreImage
import Foundation
import UIKit
@preconcurrency import Vision

struct MathVisionImage: Sendable {
    let data: Data
    let mimeType: String
}

struct MathVisionInputs: Sendable {
    let overview: MathVisionImage
    let crops: [MathVisionImage]
}

enum MathCropPlanner {
    static let overlap: CGFloat = 0.20
    static let maximumCropCount = 6

    static func cropCount(for size: CGSize) -> Int {
        guard size.width > 0, size.height > 0 else { return 3 }
        let aspect = max(size.width, size.height) / min(size.width, size.height)
        return min(maximumCropCount, max(3, Int(ceil(aspect * 2))))
    }

    /// Returns normalized rectangles in reading order with 20% overlap along the long edge.
    static func normalizedRects(for size: CGSize) -> [CGRect] {
        let count = cropCount(for: size)
        let cropLength = 1 / (1 + (1 - overlap) * CGFloat(count - 1))
        let step = cropLength * (1 - overlap)
        return (0..<count).map { index in
            let origin = min(CGFloat(index) * step, 1 - cropLength)
            if size.height >= size.width {
                return CGRect(x: 0, y: origin, width: 1, height: cropLength)
            }
            return CGRect(x: origin, y: 0, width: cropLength, height: 1)
        }
    }
}

enum MathImagePreprocessor {
    static let overviewMaximumSide: CGFloat = 1_200
    static let cropMaximumSide: CGFloat = 3_072
    static let binaryPNGMaximumBytes = 115 * 1_024

    /// Applies EXIF orientation and a conservative page-boundary correction once. The returned
    /// JPEG becomes the immutable facsimile source; OCR-specific enhancement never overwrites it.
    static func normalizeSource(_ data: Data) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let image = UIImage(data: data), let upright = redrawUpright(image) else {
                throw MathNoteError.invalidImage
            }
            let corrected = perspectiveCorrect(upright) ?? upright
            guard let encoded = corrected.jpegData(compressionQuality: 0.96) else {
                throw MathNoteError.invalidImage
            }
            return encoded
        }.value
    }

    static func rotateSource(_ data: Data, clockwise: Bool = true) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let image = UIImage(data: data), let cgImage = image.cgImage else {
                throw MathNoteError.invalidImage
            }
            let size = CGSize(width: cgImage.height, height: cgImage.width)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            let rotated = renderer.image { context in
                context.cgContext.translateBy(x: size.width / 2, y: size.height / 2)
                context.cgContext.rotate(by: clockwise ? .pi / 2 : -.pi / 2)
                context.cgContext.translateBy(x: -CGFloat(cgImage.width) / 2, y: -CGFloat(cgImage.height) / 2)
                context.cgContext.draw(
                    cgImage,
                    in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
                )
            }
            guard let encoded = rotated.jpegData(compressionQuality: 0.96) else {
                throw MathNoteError.invalidImage
            }
            return encoded
        }.value
    }

    static func prepareVisionInputs(sourceData: Data) async throws -> MathVisionInputs {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let image = UIImage(data: sourceData), let cgImage = image.cgImage else {
                throw MathNoteError.invalidImage
            }

            let overviewImage = grayscale(resize(cgImage, maximumSide: overviewMaximumSide))
            guard let overviewData = UIImage(cgImage: overviewImage).jpegData(compressionQuality: 0.76) else {
                throw MathNoteError.invalidImage
            }

            let size = CGSize(width: cgImage.width, height: cgImage.height)
            var cropInputs: [MathVisionImage] = []
            for normalizedRect in MathCropPlanner.normalizedRects(for: size) {
                try Task.checkCancellation()
                let pixelRect = CGRect(
                    x: normalizedRect.minX * size.width,
                    y: normalizedRect.minY * size.height,
                    width: normalizedRect.width * size.width,
                    height: normalizedRect.height * size.height
                ).integral.intersection(CGRect(origin: .zero, size: size))
                guard let crop = cgImage.cropping(to: pixelRect) else { continue }
                let constrained = resize(crop, maximumSide: cropMaximumSide)
                if let binary = binaryPNG(constrained), binary.count <= binaryPNGMaximumBytes {
                    cropInputs.append(MathVisionImage(data: binary, mimeType: "image/png"))
                } else {
                    let gray = grayscale(constrained)
                    guard let jpeg = UIImage(cgImage: gray).jpegData(compressionQuality: 0.74) else {
                        throw MathNoteError.invalidImage
                    }
                    cropInputs.append(MathVisionImage(data: jpeg, mimeType: "image/jpeg"))
                }
            }

            guard !cropInputs.isEmpty else { throw MathNoteError.invalidImage }
            return MathVisionInputs(
                overview: MathVisionImage(data: overviewData, mimeType: "image/jpeg"),
                crops: cropInputs
            )
        }.value
    }

    private static func redrawUpright(_ image: UIImage) -> UIImage? {
        let pixelSize: CGSize
        if let cgImage = image.cgImage {
            pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        } else {
            pixelSize = image.size
        }
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: pixelSize, format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: pixelSize))
            image.draw(in: CGRect(origin: .zero, size: pixelSize))
        }
    }

    private static func perspectiveCorrect(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 1
        request.minimumConfidence = 0.82
        request.minimumAspectRatio = 0.35
        request.minimumSize = 0.45
        request.quadratureTolerance = 20
        try? VNImageRequestHandler(cgImage: cgImage, orientation: .up).perform([request])
        guard let rectangle = request.results?.first else { return nil }

        // Do not crop when the detector finds only a small inset rectangle, such as a diagram.
        let bounds = rectangle.boundingBox
        guard bounds.width * bounds.height > 0.58 else { return nil }

        let input = CIImage(cgImage: cgImage)
        let extent = input.extent
        func vector(_ point: CGPoint) -> CIVector {
            CIVector(
                x: extent.minX + point.x * extent.width,
                y: extent.minY + point.y * extent.height
            )
        }
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(vector(rectangle.topLeft), forKey: "inputTopLeft")
        filter.setValue(vector(rectangle.topRight), forKey: "inputTopRight")
        filter.setValue(vector(rectangle.bottomLeft), forKey: "inputBottomLeft")
        filter.setValue(vector(rectangle.bottomRight), forKey: "inputBottomRight")
        guard let output = filter.outputImage,
              let rendered = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(output, from: output.extent) else {
            return nil
        }
        return UIImage(cgImage: rendered)
    }

    private static func resize(_ image: CGImage, maximumSide: CGFloat) -> CGImage {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = min(1, maximumSide / max(width, height))
        guard scale < 1 else { return image }
        let outputWidth = max(1, Int((width * scale).rounded()))
        let outputHeight = max(1, Int((height * scale).rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: outputWidth,
                height: outputHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        return context.makeImage() ?? image
    }

    private static func grayscale(_ image: CGImage) -> CGImage {
        let data = NSMutableData(length: image.width * image.height)!
        guard let context = CGContext(
            data: data.mutableBytes,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let provider = CGDataProvider(data: data as CFData),
              let output = CGImage(
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: image.width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else { return image }
        return output
    }

    private static func binaryPNG(_ image: CGImage) -> Data? {
        let gray = grayscale(image)
        let count = gray.width * gray.height
        let storage = NSMutableData(length: count)!
        guard let context = CGContext(
            data: storage.mutableBytes,
            width: gray.width,
            height: gray.height,
            bitsPerComponent: 8,
            bytesPerRow: gray.width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.draw(gray, in: CGRect(x: 0, y: 0, width: gray.width, height: gray.height))

        let pixels = storage.mutableBytes.bindMemory(to: UInt8.self, capacity: count)
        var histogram = [Int](repeating: 0, count: 256)
        for index in 0..<count { histogram[Int(pixels[index])] += 1 }
        let threshold = otsuThreshold(histogram: histogram, count: count)
        for index in 0..<count { pixels[index] = Int(pixels[index]) < threshold ? 0 : 255 }

        guard let provider = CGDataProvider(data: storage as CFData),
              let output = CGImage(
                width: gray.width,
                height: gray.height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: gray.width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }
        return UIImage(cgImage: output).pngData()
    }

    private static func otsuThreshold(histogram: [Int], count: Int) -> Int {
        guard count > 0 else { return 180 }
        let totalSum = histogram.enumerated().reduce(0.0) { $0 + Double($1.offset * $1.element) }
        var backgroundWeight = 0
        var backgroundSum = 0.0
        var bestVariance = -Double.infinity
        var bestThreshold = 180
        for threshold in 0..<256 {
            backgroundWeight += histogram[threshold]
            if backgroundWeight == 0 { continue }
            let foregroundWeight = count - backgroundWeight
            if foregroundWeight == 0 { break }
            backgroundSum += Double(threshold * histogram[threshold])
            let backgroundMean = backgroundSum / Double(backgroundWeight)
            let foregroundMean = (totalSum - backgroundSum) / Double(foregroundWeight)
            let variance = Double(backgroundWeight * foregroundWeight) * pow(backgroundMean - foregroundMean, 2)
            if variance > bestVariance {
                bestVariance = variance
                bestThreshold = threshold
            }
        }
        // A slightly brighter cutoff keeps thin pencil strokes while avoiding aggressive cleanup.
        return min(235, max(95, bestThreshold + 8))
    }
}
