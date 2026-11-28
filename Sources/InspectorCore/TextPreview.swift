import Foundation

/// Short, single-line renderings of longer text for lists and timeline cards.
enum TextPreview {
    /// The first `limit` characters of `text`, with every run of whitespace collapsed to one space.
    static func singleLine(_ text: String, limit: Int = 180) -> String {
        String(text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(limit))
    }

    /// `text` with its first `<think>…</think>` block removed.
    static func withoutReasoning(_ text: String) -> String {
        var result = text
        if let start = result.range(of: LogGrammar.reasoningOpen),
            let end = result.range(of: LogGrammar.reasoningClose, range: start.upperBound..<result.endIndex)
        {
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return result
    }
}
