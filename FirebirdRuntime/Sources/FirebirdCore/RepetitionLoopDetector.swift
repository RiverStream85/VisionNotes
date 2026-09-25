import Foundation

/// Detects a degenerate generation loop: the tail of the text is the same
/// block repeated back to back. Detection stops a runaway page early instead
/// of spending the whole context budget on repeated text.
public struct RepetitionLoopDetector: Sendable {
    public struct Loop: Equatable, Sendable {
        /// Length of the repeating block, in Unicode scalars.
        public let period: Int
        /// Length of the whole repeating tail, including the first copy.
        public let length: Int
    }

    public let minimumPeriod: Int
    public let maximumPeriod: Int
    public let minimumRepeats: Int
    /// Short legitimate repetition (a zero matrix, a table rule) stays below this.
    public let minimumRepeatedCharacters: Int

    public init(minimumPeriod: Int = 2, maximumPeriod: Int = 256,
                minimumRepeats: Int = 4, minimumRepeatedCharacters: Int = 240) {
        precondition(minimumPeriod > 0 && maximumPeriod >= minimumPeriod && minimumRepeats >= 2)
        self.minimumPeriod = minimumPeriod; self.maximumPeriod = maximumPeriod
        self.minimumRepeats = minimumRepeats; self.minimumRepeatedCharacters = minimumRepeatedCharacters
    }

    /// The shortest repeating block at the end of `text`, or nil when the tail is not a loop.
    public func loop(in text: String) -> Loop? {
        let window = max(maximumPeriod * minimumRepeats, minimumRepeatedCharacters + maximumPeriod)
        let tail = Array(text.unicodeScalars.suffix(window))
        guard tail.count >= minimumRepeatedCharacters, tail.count / minimumRepeats >= minimumPeriod else { return nil }
        for period in minimumPeriod...min(maximumPeriod, tail.count / minimumRepeats) {
            // Count trailing scalars that equal the scalar one period earlier.
            var run = 0
            var index = tail.count - 1
            while index >= period, tail[index] == tail[index - period] {
                run += 1; index -= 1
            }
            let length = run + period
            if length >= period * minimumRepeats, length >= minimumRepeatedCharacters {
                return Loop(period: period, length: length)
            }
        }
        return nil
    }

    public func period(in text: String) -> Int? { loop(in: text)?.period }

    /// Keeps one copy of a trailing loop so a saved draft stays reviewable.
    /// The loop is measured inside the detection window, so a longer loop may
    /// leave a few extra copies; the draft is never extended.
    public func trimmingLoop(_ text: String) -> String {
        guard let loop = loop(in: text) else { return text }
        var scalars = String.UnicodeScalarView(text.unicodeScalars)
        scalars.removeLast(loop.length - loop.period)
        return String(scalars)
    }
}
