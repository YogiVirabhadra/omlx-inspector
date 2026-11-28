import Foundation

/// Aggregates the full turn, independent of timeline filters and pagination.
/// Context is reported prompt usage, not configured capacity or an estimated KV-cache size.
public struct TurnMetrics: Sendable {
    public let peakPromptTokens: Int?
    public let contextComplete: Bool
    public let elapsedSeconds: Double?
    public let hasTerminalCompletion: Bool

    public var contextLabel: String { contextComplete ? "Peak context" : "Peak observed context" }
    public var contextValue: String { peakPromptTokens.map { "\($0.formatted()) tokens" } ?? "Unavailable" }
    public var durationLabel: String { hasTerminalCompletion ? "Turn duration" : "Observed span" }
    public var durationValue: String {
        guard let elapsedSeconds else { return "Unavailable" }
        // Round before splitting to avoid values such as 1m 60.0s.
        let tenths = (elapsedSeconds * 10).rounded()
        if tenths < 600 { return String(format: "%.1f s", tenths / 10) }
        let minutes = Int(tenths / 600)
        let seconds = tenths.truncatingRemainder(dividingBy: 600) / 10
        if minutes < 60 { return String(format: "%dm %.1fs", minutes, seconds) }
        return String(format: "%dh %dm %.1fs", minutes / 60, minutes % 60, seconds)
    }
    public var contextHelp: String {
        "Largest oMLX-reported prompt-token count across this turn's inference requests, including retained history and tool definitions. Does not include newly generated tokens or represent the model's context limit. Request associations are inferred."
            + (contextComplete ? "" : " Some request counts are unavailable; this is only the observed maximum.")
    }
    public var durationHelp: String {
        hasTerminalCompletion
            ? "Elapsed wall time from this turn's first observed incoming request to its last associated terminal server completion, including time between inferences and tool-result round trips. Turn grouping and completion associations are inferred. Does not measure time before oMLX received the request or after its final completion."
            : "Elapsed time from this turn's first observed incoming request to its latest observed evidence. A final turn completion is not established; this is not a completed duration or a running clock. Tool-call completion alone does not establish that the turn finished."
    }
}

public extension InspectorTurn {
    /// Context and duration figures for the whole turn.
    var metrics: TurnMetrics {
        let requests = events.filter { $0.kind == .request }
        let counts = requests.compactMap { $0.completion?.promptTokens ?? $0.metrics?.promptTokens }
        let last = requests.last?.completion
        let terminal =
            last?.finishReason.map { ["stop", "length", "content_filter", "error", "failed"].contains($0) } ?? false
        let end =
            terminal
            ? last?.timestamp : (events.map(\.timestamp) + requests.compactMap { $0.completion?.timestamp }).max()
        let elapsed = requests.first.flatMap { first in
            end.flatMap { EvidenceBuilder.elapsedSeconds(from: first.timestamp, to: $0) }
        }
        .flatMap { $0 >= 0 ? $0 : nil }
        return TurnMetrics(
            peakPromptTokens: counts.max(), contextComplete: !requests.isEmpty && counts.count == requests.count,
            elapsedSeconds: elapsed, hasTerminalCompletion: terminal && elapsed != nil)
    }
}
