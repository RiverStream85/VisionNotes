import CoreGraphics
import Foundation

/// Assigns a natural reading order to unordered OCR observations.
///
/// The concrete algorithm is deliberately behind a protocol: a smarter layout
/// analyser can replace `ReadingOrderSorter` later without touching the OCR
/// service or the persistence layer.
protocol TextBlockOrdering: Sendable {
    /// Returns the blocks sorted, with `readingOrder` set to their new index.
    func ordered(_ blocks: [RecognizedTextBlock]) -> [RecognizedTextBlock]
}

/// Top-to-bottom, left-to-right ordering with simple two-column detection.
struct ReadingOrderSorter: TextBlockOrdering {
    /// Blocks whose vertical spans overlap by more than this fraction of the
    /// shorter block are treated as being on the same line.
    var sameLineOverlapRatio: Double = 0.35
    /// Whether to look for an obvious two-column layout before sorting.
    var detectsColumns: Bool = true

    init(sameLineOverlapRatio: Double = 0.35, detectsColumns: Bool = true) {
        self.sameLineOverlapRatio = sameLineOverlapRatio
        self.detectsColumns = detectsColumns
    }

    func ordered(_ blocks: [RecognizedTextBlock]) -> [RecognizedTextBlock] {
        guard blocks.count > 1 else { return reindexed(blocks) }
        let columns = detectsColumns ? splitIntoColumns(blocks) : [blocks]
        let sorted = columns.flatMap { sortWithinColumn($0) }
        return reindexed(sorted)
    }

    /// Groups blocks into visual lines, top line first, each line ordered
    /// left-to-right. Used both for sorting and for composing page text.
    func lines(from blocks: [RecognizedTextBlock]) -> [[RecognizedTextBlock]] {
        // Vision's Y axis grows upwards, so the top of the page is the largest Y.
        let topDown = blocks.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        var lines: [[RecognizedTextBlock]] = []
        for block in topDown {
            if let index = lines.indices.last, belongsToLine(block, line: lines[index]) {
                lines[index].append(block)
            } else {
                lines.append([block])
            }
        }
        return lines.map { $0.sorted { $0.boundingBox.minX < $1.boundingBox.minX } }
    }

    // MARK: - Private

    private func sortWithinColumn(_ blocks: [RecognizedTextBlock]) -> [RecognizedTextBlock] {
        lines(from: blocks).flatMap { $0 }
    }

    private func belongsToLine(_ block: RecognizedTextBlock, line: [RecognizedTextBlock]) -> Bool {
        guard let reference = line.last else { return false }
        return sharesLine(block.boundingBox, reference.boundingBox)
    }

    /// True when two rects overlap vertically enough to be one visual line.
    func sharesLine(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        guard overlap > 0 else { return false }
        let shorter = min(a.height, b.height)
        guard shorter > 0 else { return false }
        return overlap / shorter >= sameLineOverlapRatio
    }

    /// Returns `[left, right]` for an obvious two-column page, otherwise a
    /// single group. Anything that straddles the gutter disables the split,
    /// which keeps full-width headings from being reordered.
    private func splitIntoColumns(_ blocks: [RecognizedTextBlock]) -> [[RecognizedTextBlock]] {
        let gutter = 0.5
        let tolerance = 0.02
        var left: [RecognizedTextBlock] = []
        var right: [RecognizedTextBlock] = []
        var spanning: [RecognizedTextBlock] = []

        for block in blocks {
            if block.boundingBox.maxX <= gutter + tolerance {
                left.append(block)
            } else if block.boundingBox.minX >= gutter - tolerance {
                right.append(block)
            } else {
                spanning.append(block)
            }
        }

        guard spanning.isEmpty, left.count >= 2, right.count >= 2 else {
            return [blocks]
        }
        return [left, right]
    }

    private func reindexed(_ blocks: [RecognizedTextBlock]) -> [RecognizedTextBlock] {
        blocks.enumerated().map { $0.element.withReadingOrder($0.offset) }
    }
}

/// Joins ordered blocks into the plain text stored on a `DocumentPage`.
enum PageTextComposer {
    /// Merges blocks that already sit next to each other in reading order and
    /// share a visual line; every other block starts a new line. Working from
    /// the existing order (instead of re-grouping by Y) keeps column layouts
    /// intact.
    static func composeText(
        from blocks: [RecognizedTextBlock],
        sorter: ReadingOrderSorter = ReadingOrderSorter()
    ) -> String {
        guard !blocks.isEmpty else { return "" }
        let ordered = blocks.sorted { $0.readingOrder < $1.readingOrder }
        var lines: [[String]] = []
        var previous: RecognizedTextBlock?

        for block in ordered {
            let text = block.text.trimmingCharacters(in: .whitespaces)
            let continuesLine = previous.map { earlier in
                sorter.sharesLine(block.boundingBox, earlier.boundingBox)
                    && block.boundingBox.minX >= earlier.boundingBox.minX
            } ?? false

            if continuesLine, !lines.isEmpty {
                lines[lines.count - 1].append(text)
            } else {
                lines.append([text])
            }
            previous = block
        }

        return lines
            .map { $0.filter { !$0.isEmpty }.joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
