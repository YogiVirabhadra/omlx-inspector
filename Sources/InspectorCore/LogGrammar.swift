import Foundation

/// Supported log syntax. Nil levels deliberately preserve older acceptance at
/// any level. Dispatch stays in the consumers so precedence remains explicit.
enum LogGrammar {
    struct Pattern: Sendable {
        let id: String
        let logger: String?
        let level: String?
        let prefix: String?
        /// The regular expression source.
        let regex: String?
        /// `regex`, compiled once. Compiling per call dominated per-record parsing cost.
        let expression: NSRegularExpression?

        init(id: String, logger: String? = nil, level: String? = nil, prefix: String? = nil, regex: String? = nil) {
            self.id = id
            self.logger = logger
            self.level = level
            self.prefix = prefix
            self.regex = regex
            // The patterns are constants; `LogGrammarTests` exercises every one of them.
            expression = regex.map { source in
                do {
                    return try NSRegularExpression(pattern: source)
                } catch {
                    preconditionFailure("Invalid log grammar pattern \(id): \(error)")
                }
            }
        }

        func captures(in record: LogRecord) -> [String]? {
            guard logger == nil || logger == record.logger,
                level == nil || level == record.level
            else { return nil }
            return captures(in: record.body)
        }
        func captures(in body: String) -> [String]? {
            if let prefix, !body.hasPrefix(prefix) { return nil }
            guard let expression else { return [] }
            guard let match = expression.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) else {
                return nil
            }
            // Groups that did not take part in the match are returned as empty strings.
            return (1..<match.numberOfRanges).map {
                Range(match.range(at: $0), in: body).map { String(body[$0]) } ?? ""
            }
        }
        func matches(_ record: LogRecord) -> Bool { captures(in: record) != nil }
    }

    static let schedulerAdded = Pattern(
        id: "schedulerAdded", logger: "omlx.scheduler", regex: #"^Added request (\S+) with (\d+) prompt tokens"#)
    static let schedulerFinished = Pattern(
        id: "schedulerFinished", logger: "omlx.scheduler", regex: #"^Request (\S+) finished:"#)
    static let finishedTokens = Pattern(id: "finishedTokens", regex: #"finished: .*, (\d+) tokens"#)
    static let generatedOutput = Pattern(
        id: "generatedOutput", logger: "omlx.scheduler", regex: #"^Request (\S+) generated text:"#)
    static let backgroundProcess = Pattern(
        id: "backgroundProcess", regex: #"^\[IMPORTANT: Background process ([A-Za-z0-9_-]+) completed"#)
    static let completionFields = Pattern(
        id: "completionFields", logger: "omlx.server", level: "INFO",
        regex:
            #"^Chat completion: model=([^,]+), (\d+) tokens in ([0-9]+(?:\.[0-9]+)?)s \([^\r\n]*?\), prompt: (\d+)(?:,|$)"#
    )
    static let finishReason = Pattern(id: "finishReason", regex: #"(?:^|,\s*)finish_reason=([^,\r\n]*)"#)
    static let engineAbort = Pattern(
        id: "engineAbort", logger: "omlx.engine.vlm", level: "INFO",
        regex: #"^\[vlm_stream_generate\] Aborting request ([A-Za-z0-9_-]+)$"#)
    static let schedulerAbort = Pattern(
        id: "schedulerAbort", logger: "omlx.scheduler", level: "DEBUG", regex: #"^Aborted request ([A-Za-z0-9_-]+)$"#)
    static let orphanCleanup = Pattern(
        id: "orphanCleanup", logger: "omlx.engine_core", level: "DEBUG",
        regex: #"^Reaped (\d+) orphaned output collector\(s\) after disconnect: (\[[^\r\n]*\])$"#)
    static let requestID = Pattern(id: "requestID", regex: #"^([A-Za-z0-9_-]+)$"#)
    static let recordRequestID = Pattern(
        id: "recordRequestID",
        regex:
            #"^(?:Added request |Request |Aborted request |\[vlm_stream_generate\] Aborting request )([A-Za-z0-9_-]+)(?:\s|:|$)"#
    )
    /// Compiled ``header``; matches the first line of every framed record.
    static let headerExpression = header.expression!
    static let header = Pattern(
        id: "header",
        regex:
            #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3}) - ([A-Za-z0-9_.]+) - (TRACE|DEBUG|INFO|WARNING|ERROR|CRITICAL) - \[([^\]\r\n]*)\] - (.*)$"#
    )
    static let incomingRequest = Pattern(
        id: "incomingRequest", logger: "omlx.server", prefix: "Incoming POST /v1/chat/completions — body:")
    static let completionSummary = Pattern(
        id: "completionSummary", logger: "omlx.server", level: "INFO", prefix: "Chat completion:")

    /// Levels surfaced as diagnostics and highlighted in Log Records.
    static let problemLevels: Set<String> = ["WARNING", "ERROR", "CRITICAL"]

    static let requestBodySeparator = " — body: "
    static let generatedBodySeparator = "generated text:\n"
    static let incompleteRecordPrefix = "Incomplete final record"
    static let unknownLogger = "unknown"
    static let backgroundNotificationMarker =
        "[INTERNAL NOTIFICATION — generated by the Hermes gateway, not written by a human user."
    static let toolIntentMarkers = ["<|tool_call>", "<tool_call>"]
    static let reasoningOpen = "<think>"
    static let reasoningClose = "</think>"
    static let resultWrapperOpen = "<untrusted_tool_result "
    static let resultWrapperClose = "</untrusted_tool_result>"
    static let resultWrapperSeparator = "\n\n"

    static let all: [Pattern] = [
        schedulerAdded, schedulerFinished, finishedTokens, generatedOutput, backgroundProcess, completionFields,
        finishReason, engineAbort, schedulerAbort, orphanCleanup, requestID, recordRequestID, header, incomingRequest,
        completionSummary
    ]
}
