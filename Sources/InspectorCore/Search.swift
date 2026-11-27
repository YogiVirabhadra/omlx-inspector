import Foundation

public struct SearchHit: Identifiable, Sendable {
    public var id: String { event.id }
    public var turnID: String
    public var turnTitle: String
    public var event: InspectorEvent
    public var preview: String
}
public struct SearchResults: Sendable {
    public var hits: [SearchHit]
    public var limited: Bool
}
public extension LogReader {
    /// Full selected-event content, not just the abbreviated timeline preview.
    static func search(_ query: String, snapshot: LogSnapshot, limit: Int = 200) throws -> SearchResults {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return SearchResults(hits: [], limited: false) }
        var hits: [SearchHit] = []
        for turn in snapshot.turns {
            for event in turn.events {
                try Task.checkCancellation()
                let match: String? = try autoreleasepool {
                    let detail = try detail(event, snapshot: snapshot, includeTree: false)
                    let text = [event.title, event.toolID ?? "", event.requestID ?? "", detail.structured].joined(separator: "\n")
                    guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
                    let start = text.index(range.lowerBound, offsetBy: -50, limitedBy: text.startIndex) ?? text.startIndex
                    return preview(String(text[start...].prefix(260)), limit: 240)
                }
                if let match {
                    if hits.count == limit { return SearchResults(hits: hits, limited: true) }
                    hits.append(SearchHit(turnID: turn.id, turnTitle: turn.title, event: event, preview: match))
                }
            }
        }
        return SearchResults(hits: hits, limited: false)
    }
    static func metricsSummary(_ event: InspectorEvent, snapshot: LogSnapshot) -> String {
        guard let m = event.metrics else { return "" }
        var lines = ["", "", "CONTEXT & EXECUTION"]
        if let tokens = event.completion?.promptTokens ?? m.promptTokens {
            lines.append("Prompt tokens: \(tokens.formatted()) · \(event.completion == nil ? "scheduler-reported" : "completion-reported"); request association inferred")
            if let priorID = m.previousRequest, !m.possibleReset,
               let prior = snapshot.turns.lazy.flatMap(\.events).first(where: { $0.id == priorID })?.metrics?.promptTokens {
                let delta = tokens - prior
                lines.append("Prompt-token change: \(delta >= 0 ? "+" : "")\(delta.formatted())")
            }
        } else { lines.append("Prompt-token count unavailable: no unambiguous scheduler association.") }
        if let tokens = event.completion?.generatedTokens ?? m.generatedTokens {
            lines.append("Generated tokens: \(tokens.formatted()) · \(event.completion == nil ? "scheduler-reported" : "completion-reported")")
        }
        if let duration = m.elapsedSeconds { lines.append(String(format: "Scheduler elapsed: %.3f s · added to finished, not server completion duration", duration)) }
        if let completion = event.completion {
            lines.append(contentsOf: completionLines(completion))
        } else {
            lines += ["Finish reason: unavailable · no reliably associated server INFO record",
                      "Completion status: unverified · scheduler finish or generated output alone does not establish the server finish reason"]
        }
        if m.possibleReset {
            lines.append("Possible context reset or instruction change. Comparison uses a unique overlapping history with the same latest user message; continuity is NOT established and conversations were not merged.")
        }
        if m.previousRequest != nil {
            lines.append(m.changedFields.isEmpty ? "Request settings and system instructions unchanged." : "Changed request fields: " + m.changedFields.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}

extension LogReader {
    static func completionLines(_ completion: InferenceCompletion) -> [String] {
        var lines = [String(format: "Inference duration: %.2f s · server-reported completion duration", completion.duration),
                     "Finish reason: " + (completion.finishReason ?? "unavailable") + " · server INFO record",
                     "Completion status: " + completion.status,
                     completion.association,
                     "Completion evidence: lines \(completion.source.line)–\(completion.source.endLine) · available in Source → Completion INFO"]
        if completion.finishReason == "tool_calls" || completion.finishReason == "function_call" {
            lines.append("Tool execution: not established by this completion; inspect the separately reported tool calls and results.")
        }
        return lines
    }
    static func completionSummary(_ completion: InferenceCompletion?) -> String {
        guard let completion else { return "" }
        return "\n\nCONTEXT & EXECUTION\n\n" + (["Prompt tokens: \(completion.promptTokens.formatted()) · completion-reported",
            "Generated tokens: \(completion.generatedTokens.formatted()) · completion-reported"] + completionLines(completion)).joined(separator: "\n")
    }
}
