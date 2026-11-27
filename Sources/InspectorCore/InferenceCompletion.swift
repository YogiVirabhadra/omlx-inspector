import Foundation

/// Values observed in a server INFO record. Association to the request is inferred,
/// never the finish reason itself. The original record remains separately verifiable.
public struct InferenceCompletion: Sendable, Equatable {
    public var model: String
    public var promptTokens: Int
    public var generatedTokens: Int
    public var duration: Double
    public var finishReason: String?
    public var source: SourceRef
    public var timestamp: String

    public var label: String {
        switch finishReason {
        case "tool_calls": "Tool calls"
        case "stop": "Stop"
        case "length": "Length limit"
        case "content_filter": "Content filter"
        case "function_call": "Function call"
        case .none: "Finish unavailable"
        default: finishReason!.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
        }
    }
    public var status: String {
        switch finishReason {
        case "stop", "tool_calls", "function_call": "Completed"
        case "length": "Completed at length limit"
        case "content_filter": "Completion reported · content filtered"
        case "error", "failed": "Error reported"
        default: "Completion reported · outcome unspecified"
        }
    }
    public var association: String {
        "Inferred association: one isolated incoming request through server completion; matching model, prompt/output token counts, scheduler UUID, generated output, and completion timing. The INFO record has no request UUID."
    }

    static func parse(_ record: LogRecord) -> InferenceCompletion? {
        guard record.logger == "omlx.server", record.level == "INFO",
              let parts = LogReader.captures(#"^Chat completion: model=([^,]+), (\d+) tokens in ([0-9]+(?:\.[0-9]+)?)s \([^\r\n]*?\), prompt: (\d+)(?:,|$)"#, record.body),
              let generated = Int(parts[1]), let duration = Double(parts[2]), duration.isFinite,
              let prompt = Int(parts[3]) else { return nil }
        let value = LogReader.captures(#"(?:^|,\s*)finish_reason=([^,\r\n]*)"#, record.body)?.first?.trimmingCharacters(in: .whitespaces)
        let reason = value.flatMap { ["", "none", "null", "unavailable"].contains($0.lowercased()) ? nil : $0 }
        return InferenceCompletion(model: parts[0].trimmingCharacters(in: .whitespaces), promptTokens: prompt,
                                   generatedTokens: generated, duration: duration, finishReason: reason,
                                   source: record.source, timestamp: record.timestamp)
    }
}

extension EvidenceBuilder {
    struct CompletionWindow: Sendable {
        var turn: Int
        var event: Int
        var schedulerID: String?
        var finishedAt: String?
        var outputAt: String?
        var outputEvent: Int?
    }

    private mutating func rejectCompletion(_ record: LogRecord, reason: String) {
        // Preserve the source in existing, unattributed diagnostics; never add it to an inference cycle.
        diagnostic(record, title: "Unassociated completion summary",
                   note: reason + " Original INFO evidence is available in Source; no request association or outcome is inferred.")
        warn(reason + " See Log diagnostics for the original INFO record.")
    }

    mutating func consumeCompletion(_ record: LogRecord) {
        defer {
            completionOpen = max(0, completionOpen - 1)
            if completionOpen == 0 { completionOverlap = false }
            completionWindow = nil
        }
        let parsed = InferenceCompletion.parse(record)
        observePossibleActiveCompletion(parsed)
        guard let completion = parsed else {
            rejectCompletion(record, reason: "The server completion summary could not be parsed.")
            return
        }
        // Keep all overlapping HTTP lifetimes ambiguous, including a new request
        // arriving after scheduler finish but before the preceding server summary.
        guard completionOpen == 1, !completionOverlap, active.isEmpty, pending.isEmpty,
              let window = completionWindow, window.schedulerID != nil,
              let finished = window.finishedAt, let outputTime = window.outputAt, let outputIndex = window.outputEvent else {
            let reason = completionOpen == 0
                ? "No open incoming request could be associated with this server completion."
                : completionOpen > 1 || completionOverlap
                    ? "Overlapping or unresolved request lifetimes prevent a reliable completion association."
                    : "The request, scheduler finish, or generated output needed for completion association is unavailable or ambiguous."
            rejectCompletion(record, reason: reason)
            return
        }
        let request = turns[window.turn].events[window.event]
        guard request.metrics?.model == completion.model,
              request.metrics?.promptTokens == completion.promptTokens,
              request.metrics?.generatedTokens == completion.generatedTokens,
              let outputDelay = Self.elapsed(outputTime, record.timestamp), (0...5).contains(outputDelay),
              let finishedDelay = Self.elapsed(finished, outputTime), finishedDelay >= 0,
              let requestDuration = Self.elapsed(request.timestamp, record.timestamp),
              completion.duration <= requestDuration + 0.02,
              let schedulerDuration = request.metrics?.elapsedSeconds,
              completion.duration + 0.02 >= schedulerDuration else {
            rejectCompletion(record, reason: "The server completion could not be reliably associated; model, token counts, or timing did not agree.")
            return
        }
        turns[window.turn].events[window.event].completion = completion
        turns[window.turn].events[outputIndex].completion = completion
    }
}
