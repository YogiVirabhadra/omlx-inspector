import Foundation

/// Conversions from decoded JSON values to display and comparison text.
enum JSONText {
    /// A JSON value as display text: strings verbatim, `null` as empty, everything else pretty-printed.
    static func displayText(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let text = value as? String { return text }
        return prettyPrinted(value)
    }

    /// Pretty-printed JSON with sorted keys, or a description if `value` is not JSON.
    static func prettyPrinted(_ value: Any) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
        else { return String(describing: value) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Objects with multi-line string values as `key:` blocks; anything else pretty-printed.
    static func readableText(_ value: Any) -> String {
        guard let entries = value as? [String: Any],
            entries.values.contains(where: { ($0 as? String)?.contains("\n") == true })
        else { return prettyPrinted(value) }
        return entries.keys.sorted().map { key in key + ":\n" + displayText(entries[key]) }.joined(separator: "\n\n")
    }

    /// A SHA-256 fingerprint of sorted-key JSON. Used to compare message histories, so it must
    /// always be computed from the original decoded values.
    static func fingerprint(_ value: Any) -> String {
        let data =
            (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
        return SHA256Hex.digest(of: data)
    }
}
