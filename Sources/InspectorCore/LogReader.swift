import Foundation
import CryptoKit

struct LogRecord: Sendable {
    var source: SourceRef
    var timestamp: String
    var logger: String
    var level: String
    var body: String
}

public enum LogReader {
    static let maximumRecord = 64 * 1024 * 1024
    static let header = try! NSRegularExpression(pattern: #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3}) - ([A-Za-z0-9_.]+) - (TRACE|DEBUG|INFO|WARNING|ERROR|CRITICAL) - \[[^\]\r\n]*\] - (.*)$"#)
    static func captures(_ pattern: String, _ value: String) -> [String]? {
        guard let r = try? NSRegularExpression(pattern: pattern), let m = r.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        return (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: value).map { String(value[$0]) } ?? "" }
    }
    static func metadata(_ url: URL) throws -> (UInt64, UInt64, Date) {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        guard a[.type] as? FileAttributeType == .typeRegular else { throw InspectorError.invalid("Choose a regular log file.") }
        return ((a[.size] as? NSNumber)?.uint64Value ?? 0, (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0, a[.modificationDate] as? Date ?? .distantPast)
    }
    static func json(_ record: LogRecord) throws -> [String: Any] {
        guard let range = record.body.range(of: " — body: "), let x = try JSONSerialization.jsonObject(with: Data(record.body[range.upperBound...].utf8)) as? [String: Any] else { throw InspectorError.invalid("Unsupported request body") }
        return x
    }
    static func string(_ x: Any?) -> String {
        guard let x, !(x is NSNull) else { return "" }
        if let s = x as? String { return s }
        return pretty(x)
    }
    static func pretty(_ x: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: x, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]) else { return String(describing: x) }
        return String(decoding: data, as: UTF8.self)
    }
    static func preview(_ s: String, limit: Int = 180) -> String { String(s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(limit)) }
    static func resultPayload(_ content: String) -> String {
        if content.hasPrefix("<untrusted_tool_result "), let end = content.range(of: "</untrusted_tool_result>", options: .backwards), let start = content.range(of: "\n\n"), start.upperBound < end.lowerBound {
            return String(content[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return content
    }
    static func resultSummary(_ content: String) -> String {
        let payload = resultPayload(content)
        if let d = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] {
            let failure = (d["success"] as? Bool == false) || ((d["exit_code"] as? Int ?? 0) != 0) || !(string(d["error"]).isEmpty)
            if failure {
                let explanation = [string(d["error"]), string(d["stderr"]).split(separator: "\n").last.map(String.init) ?? "", string(d["output"])].first { !$0.isEmpty } ?? "Nonzero exit code or unsuccessful result"
                return "Reported error · " + preview(explanation)
            }
            if !string(d["output"]).isEmpty { return preview(string(d["output"])) }
        }
        return preview(payload)
    }
    static func readableObject(_ x: Any) -> String {
        guard let d = x as? [String: Any], d.values.contains(where: { ($0 as? String)?.contains("\n") == true }) else { return pretty(x) }
        return d.keys.sorted().map { key in key + ":\n" + string(d[key]) }.joined(separator: "\n\n")
    }
    static func withoutReasoning(_ text: String) -> String {
        var result = text
        if let start = result.range(of: "<think>"), let end = result.range(of: "</think>", range: start.upperBound..<result.endIndex) { result.removeSubrange(start.lowerBound..<end.upperBound) }
        return result
    }
    static func fingerprint(_ x: Any) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: x, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }
    public static func load(_ url: URL) throws -> LogSnapshot {
        var index = LogIndex(url: url)
        guard let update = try index.refresh() else { throw InspectorError.invalid("Unable to index source.") }
        return update.snapshot
    }
    static func sourceText(_ source: SourceRef, snapshot: LogSnapshot) throws -> String {
        let (size, inode, modified) = try metadata(snapshot.url)
        guard inode == snapshot.inode, size >= snapshot.size, size != snapshot.size || modified == snapshot.modified else { throw InspectorError.invalid("The source was replaced, truncated, or rewritten. Reopen the log before inspecting its evidence.") }
        let h = try FileHandle(forReadingFrom: snapshot.url); defer { try? h.close() }
        try h.seek(toOffset: source.offset)
        let data = try h.read(upToCount: source.length) ?? Data()
        guard data.count == source.length else { throw InspectorError.invalid("Source content is no longer available. Reopen the log.") }
        guard SHA256.hash(data: data).description == source.digest else { throw InspectorError.invalid("This source record has changed since the snapshot was opened. Reopen the log.") }
        return String(decoding: data, as: UTF8.self)
    }
    public static func detail(_ event: InspectorEvent, snapshot: LogSnapshot, includeTree: Bool = true) throws -> EventDetail {
        try Task.checkCancellation()
        let raw = try sourceText(event.evidence.source, snapshot: snapshot)
        let completionRaw = try event.completion.map { try sourceText($0.source, snapshot: snapshot) }
        if let range = raw.range(of: " — body: "), let obj = try? JSONSerialization.jsonObject(with: Data(raw[range.upperBound...].utf8)), let x = obj as? [String: Any] {
            if let index = event.evidence.message, let messages = x["messages"] as? [[String: Any]], messages.indices.contains(index) {
                let m = messages[index]
                if let c = event.evidence.call, let calls = m["tool_calls"] as? [[String: Any]], calls.indices.contains(c) {
                    let call = calls[c]; let fn = call["function"] as? [String: Any] ?? [:]
                    let args = string(fn["arguments"])
                    let formatted = (try? JSONSerialization.jsonObject(with: Data(args.utf8))).map(readableObject) ?? args
                    return EventDetail(readable: formatted, structured: pretty(call), raw: raw, tree: includeTree ? try? StructuredValue.parse(pretty(call)) : nil)
                }
                var readable = string(m["content"])
                // Reasoning stays in the structured representation, separately identified by its original key.
                if readable.isEmpty { readable = "No text content. See Structured for the complete message, including any reasoning or tool calls." }
                if m["role"] as? String == "tool" {
                    let payload = resultPayload(readable)
                    let wrapper = payload != readable
                    readable = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))).map(readableObject) ?? payload
                    if wrapper { readable = "[Agent safety wrapper collapsed; complete message in Structured / Source]\n\n" + readable }
                } else if let parsed = try? JSONSerialization.jsonObject(with: Data(readable.utf8)) { readable = pretty(parsed) }
                return EventDetail(readable: readable, structured: pretty(m), raw: raw, tree: includeTree ? try? StructuredValue.parse(pretty(m)) : nil)
            }
            return EventDetail(readable: event.kind == .request ? requestSummary(x, continuation: event.continuation) + metricsSummary(event, snapshot: snapshot) : pretty(x), structured: pretty(x), raw: raw, tree: includeTree ? try? StructuredValue.parse(pretty(x), retainedMessages: event.continuation?.retainedMessages) : nil, completionRaw: completionRaw)
        }
        let readable: String
        if event.evidence.generated, let range = raw.range(of: "generated text:\n") { readable = String(raw[range.upperBound...]) }
        else { readable = raw }
        var display = readable
        if let start = display.range(of: "<think>"), let end = display.range(of: "</think>", range: start.upperBound..<display.endIndex) {
            display.replaceSubrange(start.lowerBound..<end.upperBound, with: "[Reasoning collapsed — available in Structured and Source]\n")
        }
        return EventDetail(readable: display + completionSummary(event.completion), structured: readable, raw: raw, tree: includeTree ? try? StructuredValue.parse(readable) : nil, completionRaw: completionRaw)
    }
}
