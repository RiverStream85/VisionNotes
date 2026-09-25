import Foundation

/// Accuracy metrics for the evaluation harness. They compare a transcription
/// against a hand-checked reference; they never call the model.
public enum TranscriptionMetrics {
    /// Removes formatting that does not change meaning: whitespace and the
    /// choice of math delimiter (`$`, `$$`, `\(`, `\)`, `\[`, `\]`).
    public static func normalized(_ text: String) -> String {
        var value = text
        for delimiter in ["$$", "\\[", "\\]", "\\(", "\\)", "$"] {
            value = value.replacingOccurrences(of: delimiter, with: "")
        }
        return String(value.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(Character.init))
    }

    /// Levenshtein distance over Unicode scalars, using two rows of memory.
    public static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs.unicodeScalars), b = Array(rhs.unicodeScalars)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(substitution, previous[j] + 1, current[j - 1] + 1)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Character error rate after normalization: edits divided by reference length.
    public static func characterErrorRate(prediction: String, reference: String) -> Double {
        let p = normalized(prediction), r = normalized(reference)
        guard !r.isEmpty else { return p.isEmpty ? 0 : 1 }
        return Double(editDistance(p, r)) / Double(r.unicodeScalars.count)
    }
}
