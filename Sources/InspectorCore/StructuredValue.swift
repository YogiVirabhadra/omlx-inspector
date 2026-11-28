import Foundation
import CoreFoundation

/// Immutable nodes retain stable identity for the native outline. Only visible rows are rendered.
/// Scalar strings remain intact; previews never replace the underlying value.
public final class StructuredValue: Identifiable, Sendable {
    public enum Kind: String, Sendable { case object, array, string, number, boolean, null }
    /// The node's JSON Pointer path (RFC 6901). The root's is the empty string.
    public let id: String
    /// The object key or `[index]` under which this node appears.
    public let key: String
    /// The display label: the key, or a role or tool name for messages and tools.
    public let label: String
    public let kind: Kind
    /// A short, single-line preview. Never a substitute for the full value.
    public let preview: String
    /// Whether this is a request message introduced since the preceding inference.
    public let isNewMessage: Bool
    public let children: [StructuredValue]
    /// The complete scalar value as text; `nil` for containers.
    public let scalar: String?
    private let literal: String?
    public var isContainer: Bool { kind == .object || kind == .array }

    /// Parses JSON text into a tree.
    ///
    /// - Parameter retainedMessages: For requests, the number of leading messages carried over
    ///   from the preceding inference. Later messages are marked as new.
    public static func parse(_ text: String, retainedMessages: Int? = nil) throws -> StructuredValue {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        return StructuredValue(object, key: "Root", path: "", retainedMessages: retainedMessages)
    }
    private init(
        _ value: Any, key: String, path: String, retainedMessages: Int?, messageIndex: Int? = nil, toolIndex: Int? = nil
    ) {
        self.id = path
        self.key = key
        isNewMessage = messageIndex.map { index in retainedMessages.map { index >= $0 } ?? false } ?? false
        let object = value as? [String: Any]
        if let messageIndex {
            label = "[\(messageIndex)] \(object?["role"] as? String ?? "unknown role")"
        } else if let toolIndex, let function = object?["function"] as? [String: Any],
            let name = function["name"] as? String
        {
            label = "[\(toolIndex)] \(name)"
        } else {
            label = key
        }
        if let object {
            kind = .object
            scalar = nil
            literal = nil
            // Messages are first, while every other original key remains available.
            let keys = object.keys.sorted { lhs, rhs in
                if path.isEmpty, lhs == "messages" || rhs == "messages" { return lhs == "messages" }
                return lhs < rhs
            }
            children = keys.map { child in
                let escaped = child.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
                return StructuredValue(
                    object[child]!, key: child, path: path + "/" + escaped, retainedMessages: retainedMessages)
            }
            let hint: String
            if messageIndex != nil {
                let calls = object["tool_calls"] as? [[String: Any]] ?? []
                let names = calls.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
                hint =
                    names.isEmpty ? Self.short(JSONText.displayText(object["content"])) : names.joined(separator: ", ")
            } else {
                hint = ""
            }
            preview = "\(object.count) field\(object.count == 1 ? "" : "s")" + (hint.isEmpty ? "" : " · " + hint)
        } else if let array = value as? [Any] {
            kind = .array
            scalar = nil
            literal = nil
            children = array.enumerated().map { index, item in
                StructuredValue(
                    item, key: "[\(index)]", path: path + "/\(index)", retainedMessages: retainedMessages,
                    messageIndex: path == "/messages" ? index : nil, toolIndex: path == "/tools" ? index : nil)
            }
            let noun = path == "/messages" ? "message" : "item"
            preview = "\(array.count) \(noun)\(array.count == 1 ? "" : "s")"
        } else {
            children = []
            literal = JSONText.prettyPrinted(value)
            if let text = value as? String {
                kind = .string
                scalar = text
                preview = "\"\(Self.short(text))\""
            } else if value is NSNull {
                kind = .null
                scalar = "null"
                preview = "null"
            } else {
                kind = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true ? .boolean : .number
                scalar = literal
                preview = literal ?? ""
            }
        }
    }
    private static func short(_ value: String) -> String {
        let prefix = String(value.prefix(160))
        return prefix.split(whereSeparator: \.isWhitespace).joined(separator: " ") + (value.count > 160 ? "…" : "")
    }
    /// Valid JSON for any subtree, including empty containers and original scalar types.
    public func json(indentation: Int = 0) -> String {
        guard isContainer else { return literal ?? "null" }
        let open = kind == .object ? "{" : "["
        let close = kind == .object ? "}" : "]"
        guard !children.isEmpty else { return open + close }
        let padding = String(repeating: "  ", count: indentation + 1)
        let values = children.map { child in
            padding + (kind == .object ? JSONText.prettyPrinted(child.key) + ": " : "")
                + child.json(indentation: indentation + 1)
        }
        return open + "\n" + values.joined(separator: ",\n") + "\n" + String(repeating: "  ", count: indentation)
            + close
    }
    /// Resolve saved JSON-pointer identities against a freshly loaded detail tree.
    public func node(at path: String) -> StructuredValue? {
        if id == path { return self }
        for child in children where path == child.id || path.hasPrefix(child.id + "/") {
            if let match = child.node(at: path) { return match }
        }
        return nil
    }
    /// The complete value for reading or copying: strings verbatim, everything else as JSON.
    public var completeText: String { kind == .string ? scalar ?? "" : json() }
}
