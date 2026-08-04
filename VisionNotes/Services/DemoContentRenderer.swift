import CoreGraphics
import Foundation
import UIKit

/// Draws the sample pages used by "Load Demo Notes".
///
/// The demo content is generated, not shipped as binary assets, so the app has
/// no image files to keep in sync — and because the renderer knows exactly
/// where every line was drawn, it can hand back matching bounding boxes in
/// Vision's coordinate space. No OCR runs for demo content.
enum DemoContentRenderer {

    struct Line: Sendable {
        let text: String
        let size: CGFloat
        let bold: Bool

        init(_ text: String, size: CGFloat = 34, bold: Bool = false) {
            self.text = text
            self.size = size
            self.bold = bold
        }

        static func spacer(_ height: CGFloat = 18) -> Line {
            Line("", size: height)
        }
    }

    struct RenderedDemoPage: Sendable {
        let imageData: Data
        let thumbnailData: Data
        let blocks: [RecognizedTextBlock]
        let text: String
    }

    static let pageSize = CGSize(width: 1240, height: 1754) // A4 at ~150 dpi
    private static let margin: CGFloat = 90
    private static let lineGap: CGFloat = 16

    /// Renders one page to JPEG plus its pre-filled text blocks.
    static func renderImagePage(lines: [Line], background: UIColor = UIColor(white: 0.98, alpha: 1)) throws -> RenderedDemoPage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pageSize, format: format)

        var blocks: [RecognizedTextBlock] = []
        let image = renderer.image { context in
            background.setFill()
            context.fill(CGRect(origin: .zero, size: pageSize))
            blocks = draw(lines: lines, in: pageSize)
        }

        let cgImage = try ImageProcessor.cgImage(from: image)
        return RenderedDemoPage(
            imageData: try ImageProcessor.jpegData(from: cgImage, quality: 0.9),
            thumbnailData: try ImageProcessor.thumbnailData(from: cgImage),
            blocks: blocks,
            text: PageTextComposer.composeText(from: blocks)
        )
    }

    /// Renders a multi-page PDF plus a cached image and text blocks per page.
    static func renderPDF(pages: [[Line]]) throws -> (pdfData: Data, pages: [RenderedDemoPage]) {
        let bounds = CGRect(origin: .zero, size: pageSize)
        let pdfRenderer = UIGraphicsPDFRenderer(bounds: bounds)
        let pdfData = pdfRenderer.pdfData { context in
            for lines in pages {
                context.beginPage()
                UIColor.white.setFill()
                context.cgContext.fill(bounds)
                _ = draw(lines: lines, in: pageSize)
            }
        }

        let rendered = try pages.map { try renderImagePage(lines: $0, background: .white) }
        return (pdfData, rendered)
    }

    // MARK: - Private

    /// Draws the lines into the current graphics context and returns their
    /// bounding boxes, converted into Vision's normalized, bottom-left space.
    private static func draw(lines: [Line], in size: CGSize) -> [RecognizedTextBlock] {
        var blocks: [RecognizedTextBlock] = []
        var y = margin
        let maxWidth = size.width - margin * 2

        for line in lines {
            guard !line.text.isEmpty else {
                y += line.size
                continue
            }
            let font = UIFont.systemFont(ofSize: line.size, weight: line.bold ? .semibold : .regular)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.black
            ]
            let attributed = NSAttributedString(string: line.text, attributes: attributes)
            let measured = attributed.boundingRect(
                with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
            let height = ceil(measured.height)
            let drawRect = CGRect(x: margin, y: y, width: maxWidth, height: height)
            attributed.draw(
                with: drawRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )

            let textRect = CGRect(x: margin, y: y, width: min(ceil(measured.width), maxWidth), height: height)
            blocks.append(
                RecognizedTextBlock(
                    text: line.text,
                    confidence: 0.93,
                    boundingBox: BoundingBoxConverter.normalizedRect(fromImageRect: textRect, imageSize: size),
                    readingOrder: blocks.count
                )
            )
            y += height + lineGap
        }
        return blocks
    }
}
