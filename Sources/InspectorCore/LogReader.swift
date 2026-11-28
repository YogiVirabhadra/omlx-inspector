import Foundation

/// The public entry points for reading an oMLX log: one-shot loading, and the verified
/// detail behind an event or record.
///
/// Incremental indexing lives in ``LogIndex``, and search in `Search.swift`.
public enum LogReader {
    /// Indexes a complete log once, without monitoring.
    public static func load(_ url: URL) throws -> LogSnapshot {
        var index = LogIndex(url: url)
        // A new index always produces a snapshot; `nil` only means "unchanged since the last refresh".
        guard let update = try index.refresh() else { throw InspectorError.sourceUnavailable }
        return update.snapshot
    }
    /// The Readable, Structured, and Source representations of an event, read and verified from disk.
    ///
    /// - Parameter includeTree: Whether to build the ``StructuredValue`` outline. Search skips it.
    public static func detail(_ event: InspectorEvent, snapshot: LogSnapshot, includeTree: Bool = true) throws
        -> EventDetail
    {
        try Task.checkCancellation()
        let raw = try snapshot.verifiedText(of: event.evidence.source)
        let completionRaw = try event.completion.map { try snapshot.verifiedText(of: $0.source) }
        // Generated text is model output; it may legitimately contain the request separator.
        if !event.evidence.generated, let range = raw.range(of: LogGrammar.requestBodySeparator),
            let json = try? JSONSerialization.jsonObject(with: Data(raw[range.upperBound...].utf8)),
            let object = json as? [String: Any]
        {
            let payload = RequestPayload(raw: object)
            if let index = event.evidence.messageIndex, let messages = payload.messages,
                messages.indices.contains(index)
            {
                let message = RequestPayload.Message(raw: messages[index])
                if let callIndex = event.evidence.callIndex, let toolCalls = message.toolCalls,
                    toolCalls.indices.contains(callIndex)
                {
                    let call = toolCalls[callIndex]
                    let structured = JSONText.prettyPrinted(call.raw)
                    let formatted =
                        (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))).map(JSONText.readableText)
                        ?? call.arguments
                    return EventDetail(
                        readable: formatted, structured: structured, raw: raw,
                        tree: includeTree ? try? StructuredValue.parse(structured) : nil)
                }
                var readable = message.content
                // Reasoning stays in the structured representation, separately identified by its original key.
                if readable.isEmpty {
                    readable =
                        "No text content. See Structured for the complete message, including any reasoning or tool calls."
                }
                if message.role == "tool" {
                    let payload = ToolResultText.payload(readable)
                    let wrapper = payload != readable
                    readable =
                        (try? JSONSerialization.jsonObject(with: Data(payload.utf8))).map(JSONText.readableText)
                        ?? payload
                    if wrapper {
                        readable =
                            "[Agent safety wrapper collapsed; complete message in Structured / Source]\n\n" + readable
                    }
                } else if let parsed = try? JSONSerialization.jsonObject(with: Data(readable.utf8)) {
                    readable = JSONText.prettyPrinted(parsed)
                }
                let structured = JSONText.prettyPrinted(message.raw)
                return EventDetail(
                    readable: readable, structured: structured, raw: raw,
                    tree: includeTree ? try? StructuredValue.parse(structured) : nil)
            }
            let structured = JSONText.prettyPrinted(payload.raw)
            let readable =
                event.kind == .request
                ? DetailText.request(payload, continuation: event.continuation)
                    + DetailText.requestMetrics(event, snapshot: snapshot)
                : structured
            return EventDetail(
                readable: readable, structured: structured, raw: raw,
                tree: includeTree
                    ? try? StructuredValue.parse(structured, retainedMessages: event.continuation?.retainedMessages)
                    : nil,
                completionRaw: completionRaw)
        }
        let readable: String
        if event.evidence.generated, let range = raw.range(of: LogGrammar.generatedBodySeparator) {
            readable = String(raw[range.upperBound...])
        } else {
            readable = raw
        }
        var display = readable
        if let start = display.range(of: LogGrammar.reasoningOpen),
            let end = display.range(of: LogGrammar.reasoningClose, range: start.upperBound..<display.endIndex)
        {
            display.replaceSubrange(
                start.lowerBound..<end.upperBound, with: "[Reasoning collapsed — available in Structured and Source]\n")
        }
        return EventDetail(
            readable: display + DetailText.completionSection(event.completion), structured: readable, raw: raw,
            tree: includeTree ? try? StructuredValue.parse(readable) : nil, completionRaw: completionRaw)
    }

    /// The Structured and Source representations of one framed record, verified from disk.
    public static func detail(_ record: IndexedLogRecord, snapshot: LogSnapshot) throws -> EventDetail {
        try Task.checkCancellation()
        let raw = try snapshot.verifiedText(of: record.source)
        let first =
            raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        var body = raw
        if let match = LogGrammar.headerExpression.firstMatch(
            in: first, range: NSRange(first.startIndex..., in: first)),
            let range = Range(match.range(at: 5), in: first)
        {
            body = String(first[range])
            if let newline = raw.firstIndex(of: "\n") { body += String(raw[newline...]) }
        }
        let structured: String
        if let range = body.range(of: LogGrammar.requestBodySeparator),
            let object = try? JSONSerialization.jsonObject(
                with: Data(body[range.upperBound...].utf8), options: [.fragmentsAllowed])
        {
            structured = JSONText.prettyPrinted(object)
        } else if let object = try? JSONSerialization.jsonObject(with: Data(body.utf8), options: [.fragmentsAllowed]) {
            structured = JSONText.prettyPrinted(object)
        } else {
            var fields: [String: Any] = [
                "timestamp": record.timestamp, "level": record.level,
                "logger": record.logger, "context": record.context, "body": body
            ]
            if let id = record.requestID { fields["request_id"] = id }
            structured = JSONText.prettyPrinted(fields)
        }
        return EventDetail(
            readable: body, structured: structured, raw: raw, tree: try StructuredValue.parse(structured))
    }
}
