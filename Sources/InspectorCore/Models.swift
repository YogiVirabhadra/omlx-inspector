import Foundation

public enum EventKind: String, Sendable, CaseIterable {
    case user = "User message", request = "Inference request", output = "Model output", call = "Tool call", result = "Tool result", context = "Carried context", diagnostic = "Diagnostic"
    public var symbol: String { switch self {
    case .user: "person.fill"; case .request: "cpu"; case .output: "text.bubble"; case .call: "wrench.and.screwdriver"; case .result: "arrow.turn.down.right"; case .context: "text.alignleft"; case .diagnostic: "exclamationmark.triangle"
    } }
}
public struct SourceRef: Sendable, Hashable {
    public var offset: UInt64
    public var length: Int
    public var line: Int
    public var endLine: Int
    public var digest: String = ""
}
public struct Evidence: Sendable, Hashable {
    public var source: SourceRef
    public var message: Int? = nil
    public var call: Int? = nil
    public var generated = false
}
public struct InspectorEvent: Identifiable, Sendable {
    public var id: String
    public var kind: EventKind
    public var title: String
    public var summary: String
    public var timestamp: String
    public var note: String
    public var evidence: Evidence
    public var toolID: String? = nil
    public var linkedEvent: String? = nil
    public var requestID: String? = nil
    public var continuation: RequestContinuation? = nil
    public var metrics: RequestMetrics? = nil
    public var completion: InferenceCompletion? = nil
    public var compactSummary: String {
        guard kind == .request else { return summary }
        let text = summary.replacingOccurrences(of: " tool definitions", with: " tools")
        guard let tokens = completion?.promptTokens ?? metrics?.promptTokens else { return text }
        return text + " · \(tokens.formatted()) prompt tokens"
    }
    public var isIssue: Bool { kind == .diagnostic || (kind == .result && summary.hasPrefix("Reported error")) }
}
public struct InspectorTurn: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var group: Int
    public var observed: String
    public var events: [InspectorEvent]
    public var requests: Int { events.filter { $0.kind == .request }.count }
    public var calls: Int { events.filter { $0.kind == .call }.count }
}
public struct LogSnapshot: Sendable {
    public var url: URL
    public var size: UInt64
    public var inode: UInt64
    public var modified: Date
    public var turns: [InspectorTurn]
    public var recordCount: Int
    public var warnings: [String]
    public var generation: String = ""
    public var hasPartialRecord = false
    public var records: [IndexedLogRecord] = []
    public var requestCount: Int { turns.reduce(0) { $0 + $1.requests } }
    public var callCount: Int { turns.reduce(0) { $0 + $1.calls } }
}
public struct EventDetail: Sendable {
    public var readable: String
    public var structured: String
    public var raw: String
    public var tree: StructuredValue? = nil
    public var completionRaw: String? = nil
}
public enum InspectorError: LocalizedError {
    case invalid(String)
    case recordTooLarge(indexedEvidenceAvailable: Bool)
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .recordTooLarge(let available):
            available
                ? "Monitoring paused: a log record exceeds the 64 MiB safety limit. Previously indexed evidence remains available. The source log is unchanged; choose another log to continue."
                : "This log could not be indexed because a record exceeds the 64 MiB safety limit. No partial index was opened. The source log is unchanged; choose another log."
        }
    }
}

/// Presentation metadata derived from the exact message-prefix comparison, never parsed from diagnostic prose.
public struct RequestContinuation: Sendable {
    public var reason: String
    public var totalMessages: Int
    public var retainedMessages: Int?
    public var explanation: String? = nil
    public var messageDescription: String {
        guard let retainedMessages else { return "\(totalMessages) messages in context" }
        let added = totalMessages - retainedMessages
        return "\(added) new message\(added == 1 ? "" : "s") · \(retainedMessages) previous message\(retainedMessages == 1 ? "" : "s") retained"
    }
}

/// Non-destructive grouping of the existing observed sequence. Calls/results carried by a subsequent
/// request remain after the previous output; this is presentation order, not proof of execution timing.
public struct TimelineCycle: Identifiable, Sendable {
    public var id: String
    public var number: Int?
    public var events: [InspectorEvent]
    public var completion: InferenceCompletion? = nil
}
public extension InspectorTurn {
    func timelineCycles(showContext: Bool) -> [TimelineCycle] {
        var cycles: [TimelineCycle] = []
        var number = 0
        for event in events {
            if event.kind == .request {
                number += 1
                cycles.append(TimelineCycle(id: event.id, number: number, events: [event], completion: event.completion))
            } else {
                if cycles.isEmpty { cycles.append(TimelineCycle(id: id + "-opening", number: nil, events: [])) }
                cycles[cycles.count - 1].events.append(event)
            }
        }
        return cycles.compactMap { cycle in
            var visible = cycle
            visible.events = cycle.events.filter { showContext || $0.kind != .context }
            return visible.events.isEmpty ? nil : visible
        }
    }
}

public struct RequestMetrics: Sendable, Equatable {
    public var model: String?
    public var previousRequest: String?
    public var changedFields: [String] = []
    public var comparisonInferred = false
    public var possibleReset = false
    public var promptTokens: Int?
    public var generatedTokens: Int?
    public var schedulerStart: String?
    public var elapsedSeconds: Double?
}

public enum EventFilter: String, Sendable, CaseIterable {
    case all = "All events", requests = "Requests", tools = "Tools & results", output = "Model output", issues = "Errors & warnings", messages = "Messages"
    public func includes(_ event: InspectorEvent) -> Bool {
        switch self {
        case .all: true
        case .requests: event.kind == .request
        case .tools: event.kind == .call || event.kind == .result
        case .output: event.kind == .output
        case .issues: event.isIssue
        case .messages: event.kind == .user || event.kind == .context
        }
    }
}
