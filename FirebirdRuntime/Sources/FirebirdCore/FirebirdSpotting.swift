import CoreGraphics
import Foundation

/// One recognized text element and where it is on the page.
public struct FirebirdTextLine: Equatable, Sendable {
    public let text: String
    /// Normalized to 0...1 in Vision's convention: origin at the bottom left.
    public let boundingBox: CGRect

    public init(text: String, boundingBox: CGRect) {
        self.text = text; self.boundingBox = boundingBox
    }
}

/// PaddleOCR-VL's spotting output: each element's text followed by eight
/// `<|LOC_n|>` tokens, the corners of its quadrilateral as x, y pairs on a
/// 0...1000 grid with the origin at the top left, then a line break.
public struct FirebirdSpotting: Equatable, Sendable {
    public let lines: [FirebirdTextLine]

    public init(lines: [FirebirdTextLine]) { self.lines = lines }

    /// The elements' text in reading order, one per line, without locations.
    public var markdown: String { lines.map(\.text).joined(separator: "\n") }

    /// Parses complete elements; trailing text without its locations (an
    /// interrupted page) is dropped.
    public init(parsing output: String) {
        var lines: [FirebirdTextLine] = []
        var rest = Substring(output)
        while let group = rest.firstMatch(of: Self.locations) {
            let text = rest[..<group.range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let values = group.output.matches(of: /LOC_(\d+)/).map { Double($0.output.1)! / 1000 }
            let xs = stride(from: 0, to: 8, by: 2).map { values[$0] }
            let ys = stride(from: 1, to: 8, by: 2).map { values[$0] }
            let (left, right) = (xs.min()!, xs.max()!)
            let (top, bottom) = (ys.min()!, ys.max()!)
            if !text.isEmpty {
                lines.append(FirebirdTextLine(text: text, boundingBox: CGRect(
                    x: left, y: 1 - bottom, width: right - left, height: bottom - top)))
            }
            rest = rest[group.range.upperBound...]
        }
        self.init(lines: lines)
    }

    nonisolated(unsafe) private static let locations = /(?:<\|LOC_\d+\|>){8}/
}
