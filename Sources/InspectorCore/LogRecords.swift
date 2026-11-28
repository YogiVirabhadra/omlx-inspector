import Foundation

/// One framed source record. Full bodies stay on disk and are verified on access.
public struct IndexedLogRecord: Identifiable, Sendable, Equatable {
    /// Derived from the source offset; see ``RecordList/index(ofRecordID:)``.
    public var id: String { Identifiers.record(at: source.offset) }
    public let source: SourceRef
    public let timestamp: String
    public let logger: String
    public let level: String
    public let context: String
    /// A single-line preview of the record's opening text.
    public let summary: String
    /// The scheduler request UUID named at the start of the record, if any.
    public let requestID: String?
    /// Whether the record's level is a warning, error, or critical.
    public var isProblem: Bool { LogGrammar.problemLevels.contains(level) }

    init(_ record: LogRecord) {
        source = record.source
        timestamp = record.timestamp
        logger = record.logger
        level = record.level
        context = record.context
        // Bound preview work even for multi-megabyte request/output records.
        let opening = String(record.body.prefix(600))
        summary = TextPreview.singleLine(opening)
        requestID = LogGrammar.recordRequestID.captures(in: opening)?.first
    }
}

/// A record that matched a search, with a preview around the first match.
public struct RecordSearchHit: Identifiable, Sendable {
    public var id: String { record.id }
    public let record: IndexedLogRecord
    public let preview: String
}
/// Record search results. `limited` is `true` when more matches exist than were returned.
public struct RecordSearchResults: Sendable {
    public let hits: [RecordSearchHit]
    public let limited: Bool
}

public extension LogSnapshot {
    /// The framed record behind an event, found by binary search on source offset.
    ///
    /// - Parameter completion: Return the event's associated completion record instead.
    func record(containing event: InspectorEvent, completion: Bool = false) -> IndexedLogRecord? {
        let offset =
            completion ? event.completion?.source.offset ?? event.evidence.source.offset : event.evidence.source.offset
        // Source order is stable across live updates; avoid scanning every record per card.
        let index = records.firstIndex(atOrAfter: offset)
        return index < records.count && records[index].source.offset == offset ? records[index] : nil
    }
}
