import Foundation

/// Builders for the Readable representation's prose sections.
enum DetailText {
    /// The Readable representation of a request: totals, continuity, and the newly introduced messages.
    static func request(_ request: RequestPayload, continuation: RequestContinuation?) -> String {
        let messages = (request.messages ?? []).map(RequestPayload.Message.init(raw:))
        let retained = continuation?.retainedMessages.flatMap { (0...messages.count).contains($0) ? $0 : nil }
        let model = JSONText.displayText(request.raw["model"])
        var lines = ["Model: \(model.isEmpty ? "Unspecified" : model)"]
        lines.append(
            "Messages: \(messages.count) total"
                + (retained.map { ", \(messages.count - $0) newly introduced, \($0) retained" } ?? ""))
        lines.append("Available tools: \(request.toolCount)")
        if let continuation { lines += ["", continuation.reason] }
        if let explanation = continuation?.explanation { lines.append(explanation) }
        if let retained {
            let counts = Dictionary(grouping: messages.prefix(retained), by: \.role)
                .sorted { $0.key < $1.key }.map { "\($0.value.count) \($0.key)" }.joined(separator: " · ")
            if retained > 0 { lines.append("Retained context: " + counts) }
            lines += ["", "NEW SINCE THE PRECEDING INFERENCE"]
            if retained == messages.count { lines.append("No newly introduced messages.") }
        } else {
            lines += [
                "Change comparison unavailable: no unambiguous preceding request.", "", "MESSAGES IN THIS REQUEST"
            ]
        }
        func concise(_ text: String, limit: Int = 420) -> String {
            let prefix = String(text.prefix(limit))
            return prefix.split(whereSeparator: \.isWhitespace).joined(separator: " ") + (text.count > limit ? "…" : "")
        }
        for index in (retained ?? 0)..<messages.count {
            let message = messages[index]
            let role = message.role
            let description = role == "tool" ? "tool result" : role + " message"
            lines.append("[\(index)] \(retained == nil ? "" : "New ")\(description)")
            let content = message.content
            if role == "system" || role == "developer" {
                lines.append("Instructions · complete text in Structured")
            } else if !content.isEmpty {
                lines.append(role == "tool" ? ToolResultText.summary(content).text : concise(content))
            }
            let calls = message.toolCalls ?? []
            for call in calls {
                let name = call.name.isEmpty ? "Unnamed tool" : call.name
                lines.append(concise(name + "(" + call.arguments + ")"))
            }
            if content.isEmpty && calls.isEmpty {
                lines.append("No text content; inspect this message's fields in Structured.")
            }
            lines.append("")
        }
        lines.append(
            "Message previews are abbreviated. Structured contains complete values, tool definitions, and every request field."
        )
        return lines.joined(separator: "\n")
    }

    /// The "Context & execution" section of a request's Readable representation.
    static func requestMetrics(_ event: InspectorEvent, snapshot: LogSnapshot) -> String {
        guard let metrics = event.metrics else { return "" }
        var lines = ["", "", "CONTEXT & EXECUTION"]
        if let tokens = event.completion?.promptTokens ?? metrics.promptTokens {
            lines.append(
                "Prompt tokens: \(tokens.formatted()) · \(event.completion == nil ? "scheduler-reported" : "completion-reported"); request association inferred"
            )
            if let priorID = metrics.previousRequest, !metrics.possibleReset,
                let prior = snapshot.turns.lazy.flatMap(\.events).first(where: { $0.id == priorID })?.metrics?
                    .promptTokens
            {
                let delta = tokens - prior
                lines.append("Prompt-token change: \(delta >= 0 ? "+" : "")\(delta.formatted())")
            }
        } else {
            lines.append("Prompt-token count unavailable: no unambiguous scheduler association.")
        }
        if let tokens = event.completion?.generatedTokens ?? metrics.generatedTokens {
            lines.append(
                "Generated tokens: \(tokens.formatted()) · \(event.completion == nil ? "scheduler-reported" : "completion-reported")"
            )
        }
        if let duration = metrics.elapsedSeconds {
            lines.append(
                String(
                    format: "Scheduler elapsed: %.3f s · added to finished, not server completion duration", duration))
        }
        if let completion = event.completion {
            lines.append(contentsOf: completionLines(completion))
        } else {
            lines += [
                "Finish reason: unavailable · no reliably associated server INFO record",
                "Completion status: unverified · scheduler finish or generated output alone does not establish the server finish reason"
            ]
        }
        if metrics.possibleReset {
            lines.append(
                "Possible history rewrite, context reset, or instruction change. Comparison uses a unique overlapping history with the same latest user message; continuity is NOT established and conversations were not merged."
            )
        }
        if metrics.previousRequest != nil {
            lines.append(
                metrics.changedFields.isEmpty
                    ? "Request settings and system instructions unchanged."
                    : "Changed request fields: " + metrics.changedFields.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    /// Lines describing an associated server completion.
    static func completionLines(_ completion: InferenceCompletion) -> [String] {
        var lines = [
            String(format: "Inference duration: %.2f s · server-reported completion duration", completion.duration),
            "Finish reason: " + (completion.finishReason ?? "unavailable") + " · server INFO record",
            "Completion status: " + completion.status,
            completion.association,
            "Completion evidence: lines \(completion.source.line)–\(completion.source.endLine) · available in Source → Completion INFO"
        ]
        if completion.finishReason == "tool_calls" || completion.finishReason == "function_call" {
            lines.append(
                "Tool execution: not established by this completion; inspect the separately reported tool calls and results."
            )
        }
        return lines
    }
    /// The "Context & execution" section appended to an output's Readable representation.
    static func completionSection(_ completion: InferenceCompletion?) -> String {
        guard let completion else { return "" }
        return "\n\nCONTEXT & EXECUTION\n\n"
            + ([
                "Prompt tokens: \(completion.promptTokens.formatted()) · completion-reported",
                "Generated tokens: \(completion.generatedTokens.formatted()) · completion-reported"
            ] + completionLines(completion)).joined(separator: "\n")
    }
}
