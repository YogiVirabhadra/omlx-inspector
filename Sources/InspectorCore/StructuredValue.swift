import Foundation
import CoreFoundation

/// Immutable nodes retain stable identity for the native outline. Only visible rows are rendered.
/// Scalar strings remain intact; previews never replace the underlying value.
public final class StructuredValue: Identifiable, Sendable {
    public enum Kind: String, Sendable { case object, array, string, number, boolean, null }
    public let id: String
    public let key: String
    public let label: String
    public let kind: Kind
    public let preview: String
    public let isNewMessage: Bool
    public let children: [StructuredValue]
    public let scalar: String?
    private let literal: String?
    public var isContainer: Bool { kind == .object || kind == .array }

    public static func parse(_ text: String, retainedMessages: Int? = nil) throws -> StructuredValue {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        return StructuredValue(object, key: "Root", path: "", retainedMessages: retainedMessages)
    }
    private init(_ value: Any, key: String, path: String, retainedMessages: Int?, messageIndex: Int? = nil, toolIndex: Int? = nil) {
        self.id = path; self.key = key
        isNewMessage = messageIndex.map { index in retainedMessages.map { index >= $0 } ?? false } ?? false
        let object = value as? [String: Any]
        if let messageIndex {
            label = "[\(messageIndex)] \(object?["role"] as? String ?? "unknown role")"
        } else if let toolIndex, let function = object?["function"] as? [String: Any], let name = function["name"] as? String {
            label = "[\(toolIndex)] \(name)"
        } else { label = key }
        if let object {
            kind = .object; scalar = nil; literal = nil
            // Messages are first, while every other original key remains available.
            let keys = object.keys.sorted { a, b in
                if path.isEmpty, a == "messages" || b == "messages" { return a == "messages" }
                return a < b
            }
            children = keys.map { child in
                let escaped = child.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
                return StructuredValue(object[child]!, key: child, path: path + "/" + escaped, retainedMessages: retainedMessages)
            }
            let hint: String
            if messageIndex != nil {
                let calls = object["tool_calls"] as? [[String: Any]] ?? []
                let names = calls.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
                hint = names.isEmpty ? Self.short(LogReader.string(object["content"])) : names.joined(separator: ", ")
            } else { hint = "" }
            preview = "\(object.count) field\(object.count == 1 ? "" : "s")" + (hint.isEmpty ? "" : " · " + hint)
        } else if let array = value as? [Any] {
            kind = .array; scalar = nil; literal = nil
            children = array.enumerated().map { index, item in
                StructuredValue(item, key: "[\(index)]", path: path + "/\(index)", retainedMessages: retainedMessages,
                                messageIndex: path == "/messages" ? index : nil, toolIndex: path == "/tools" ? index : nil)
            }
            let noun = path == "/messages" ? "message" : "item"
            preview = "\(array.count) \(noun)\(array.count == 1 ? "" : "s")"
        } else {
            children = []
            literal = LogReader.pretty(value)
            if let text = value as? String {
                kind = .string; scalar = text
                preview = "\"\(Self.short(text))\""
            } else if value is NSNull {
                kind = .null; scalar = "null"; preview = "null"
            } else {
                kind = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true ? .boolean : .number
                scalar = literal; preview = literal ?? ""
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
        let open = kind == .object ? "{" : "[", close = kind == .object ? "}" : "]"
        guard !children.isEmpty else { return open + close }
        let padding = String(repeating: "  ", count: indentation + 1)
        let values = children.map { child in
            padding + (kind == .object ? LogReader.pretty(child.key) + ": " : "") + child.json(indentation: indentation + 1)
        }
        return open + "\n" + values.joined(separator: ",\n") + "\n" + String(repeating: "  ", count: indentation) + close
    }
    /// Resolve saved JSON-pointer identities against a freshly loaded detail tree.
    public func node(at path: String) -> StructuredValue? {
        if id == path { return self }
        for child in children where path == child.id || path.hasPrefix(child.id + "/") {
            if let match = child.node(at: path) { return match }
        }
        return nil
    }
    public var completeText: String { kind == .string ? scalar ?? "" : json() }
}

extension LogReader {
    static func requestSummary(_ request: [String: Any], continuation: RequestContinuation?) -> String {
        let messages = request["messages"] as? [[String: Any]] ?? []
        let retained = continuation?.retainedMessages.flatMap { (0...messages.count).contains($0) ? $0 : nil }
        var lines = ["Model: \(string(request["model"]).isEmpty ? "Unspecified" : string(request["model"]))"]
        lines.append("Messages: \(messages.count) total" + (retained.map { ", \(messages.count - $0) newly introduced, \($0) retained" } ?? ""))
        lines.append("Available tools: \((request["tools"] as? [Any])?.count ?? 0)")
        if let continuation { lines += ["", continuation.reason] }
        if let explanation = continuation?.explanation { lines.append(explanation) }
        if let retained {
            let counts = Dictionary(grouping: messages.prefix(retained), by: { $0["role"] as? String ?? "unknown" })
                .sorted { $0.key < $1.key }.map { "\($0.value.count) \($0.key)" }.joined(separator: " · ")
            if retained > 0 { lines.append("Retained context: " + counts) }
            lines += ["", "NEW SINCE THE PRECEDING INFERENCE"]
            if retained == messages.count { lines.append("No newly introduced messages.") }
        } else {
            lines += ["Change comparison unavailable: no unambiguous preceding request.", "", "MESSAGES IN THIS REQUEST"]
        }
        func concise(_ text: String, limit: Int = 420) -> String {
            let prefix = String(text.prefix(limit))
            return prefix.split(whereSeparator: \.isWhitespace).joined(separator: " ") + (text.count > limit ? "…" : "")
        }
        for index in (retained ?? 0)..<messages.count {
            let message = messages[index], role = message["role"] as? String ?? "unknown"
            let description = role == "tool" ? "tool result" : role + " message"
            lines.append("[\(index)] \(retained == nil ? "" : "New ")\(description)")
            let content = string(message["content"])
            if role == "system" || role == "developer" {
                lines.append("Instructions · complete text in Structured")
            } else if !content.isEmpty {
                lines.append(role == "tool" ? resultSummary(content) : concise(content))
            }
            for call in message["tool_calls"] as? [[String: Any]] ?? [] {
                let fn = call["function"] as? [String: Any] ?? [:]
                let name = string(fn["name"]).isEmpty ? "Unnamed tool" : string(fn["name"])
                lines.append(concise(name + "(" + string(fn["arguments"]) + ")"))
            }
            if content.isEmpty && (message["tool_calls"] as? [Any] ?? []).isEmpty { lines.append("No text content; inspect this message's fields in Structured.") }
            lines.append("")
        }
        lines.append("Message previews are abbreviated. Structured contains complete values, tool definitions, and every request field.")
        return lines.joined(separator: "\n")
    }
}
