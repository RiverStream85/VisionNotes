import CoreGraphics
import Foundation
import PDFKit
import UIKit

/// JPEG data for one PDF page: a high resolution copy for OCR and a smaller
/// one cached for the readers. Both are plain `Data` so they can cross task
/// boundaries safely.
struct RenderedPDFPage: Sendable {
    let ocrImageData: Data
    let cacheImageData: Data
    let pixelSize: CGSize
}

/// Renders single PDF pages into images for OCR and for the page cache.
protocol PDFPageRendering: Sendable {
    func pageCount(at url: URL) async throws -> Int
    /// - Parameter pageNumber: 1-based, matching `DocumentPage.pageNumber`.
    func renderPage(pageNumber: Int, at url: URL, longEdge: CGFloat) async throws -> CGImage
    /// Renders one page and encodes both sizes in a single pass, so the page
    /// bitmap is created and released exactly once.
    func renderPageImages(pageNumber: Int, at url: URL) async throws -> RenderedPDFPage
}

/// PDFKit-backed renderer.
///
/// It is an `actor` for two reasons: rendering stays off the main thread, and
/// the open `PDFDocument` is only ever touched by one task at a time. Exactly
/// one page is rasterised at a time and each image is released as soon as the
/// caller is done with it, so a 500-page PDF costs no more memory than a
/// 5-page one.
actor PDFKitPageRenderer: PDFPageRendering {

    private var cachedURL: URL?
    private var cachedDocument: PDFDocument?

    init() {}

    func pageCount(at url: URL) async throws -> Int {
        let document = try document(at: url)
        let count = document.pageCount
        guard count > 0 else {
            throw AppError.pdfDamaged(fileName: url.lastPathComponent)
        }
        return count
    }

    func renderPage(pageNumber: Int, at url: URL, longEdge: CGFloat) async throws -> CGImage {
        let document = try document(at: url)
        let index = PDFPageMapper.pageIndex(forPageNumber: pageNumber)
        guard index >= 0, index < document.pageCount, let page = document.page(at: index) else {
            throw AppError.pdfPageRenderFailed(pageNumber: pageNumber)
        }

        let bounds = page.bounds(for: .mediaBox)
        // A page rotated by 90°/270° is displayed with its axes swapped.
        let isQuarterTurned = abs(page.rotation % 180) == 90
        let displaySize = isQuarterTurned
            ? CGSize(width: bounds.height, height: bounds.width)
            : bounds.size

        guard displaySize.width > 0, displaySize.height > 0 else {
            throw AppError.pdfPageRenderFailed(pageNumber: pageNumber)
        }

        let scale = max(longEdge / max(displaySize.width, displaySize.height), 0.1)
        let targetSize = CGSize(
            width: max((displaySize.width * scale).rounded(), 1),
            height: max((displaySize.height * scale).rounded(), 1)
        )

        // `thumbnail(of:for:)` rasterises the page at the requested size and
        // already applies the page rotation.
        let image = page.thumbnail(of: targetSize, for: .mediaBox)
        guard let cgImage = image.cgImage else {
            throw AppError.pdfPageRenderFailed(pageNumber: pageNumber)
        }
        return cgImage
    }

    func renderPageImages(pageNumber: Int, at url: URL) async throws -> RenderedPDFPage {
        try Task.checkCancellation()
        let rendered = try await renderPage(
            pageNumber: pageNumber,
            at: url,
            longEdge: ImageProcessor.ocrLongEdge
        )
        let ocrData = try ImageProcessor.jpegData(from: rendered, quality: 0.85)
        let cacheImage = ImageProcessor.downscaled(rendered, longEdge: ImageProcessor.pageCacheLongEdge)
        let cacheData = try ImageProcessor.jpegData(from: cacheImage, quality: 0.7)
        return RenderedPDFPage(
            ocrImageData: ocrData,
            cacheImageData: cacheData,
            pixelSize: ImageProcessor.size(of: rendered)
        )
    }

    /// Drops any cached document, e.g. after its file was deleted.
    func invalidateCache() {
        cachedURL = nil
        cachedDocument = nil
    }

    // MARK: - Private

    private func document(at url: URL) throws -> PDFDocument {
        if let cachedDocument, cachedURL == url { return cachedDocument }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AppError.fileMissing(fileName: url.lastPathComponent)
        }
        guard let document = PDFDocument(url: url) else {
            throw AppError.pdfOpenFailed(fileName: url.lastPathComponent)
        }
        cachedURL = url
        cachedDocument = document
        return document
    }
}
