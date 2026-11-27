import Foundation

/// One framed source record. Full bodies stay on disk and are verified on access.
public struct IndexedLogRecord: Identifiable, Sendable, Equatable {
    public var id: String { "l\(source.offset)" }
    public let source: SourceRef
    public let timestamp: String
    public let logger: String
    public let level: String
    public let context: String
    public let summary: String
    public let requestID: String?

    init(_ record: LogRecord) {
        source = record.source; timestamp = record.timestamp; logger = record.logger
        level = record.level; context = record.context
        // Bound preview work even for multi-megabyte request/output records.
        let opening = String(record.body.prefix(600))
        summary = LogReader.preview(opening)
        requestID = LogReader.captures(#"^(?:Added request |Request |Aborted request |\[vlm_stream_generate\] Aborting request )([A-Za-z0-9_-]+)(?:\s|:|$)"#, opening)?.first
    }
}

public struct RecordSearchHit: Identifiable, Sendable {
    public var id: String { record.id }
    public let record: IndexedLogRecord
    public let preview: String
}
public struct RecordSearchResults: Sendable {
    public let hits: [RecordSearchHit]
    public let limited: Bool
}

public extension LogSnapshot {
    func record(containing event: InspectorEvent, completion: Bool = false) -> IndexedLogRecord? {
        let offset = completion ? event.completion?.source.offset ?? event.evidence.source.offset : event.evidence.source.offset
        // Source order is stable across live updates; avoid scanning every record per card.
        var low = 0, high = records.count
        while low < high {
            let mid = (low + high) / 2
            if records[mid].source.offset < offset { low = mid + 1 } else { high = mid }
        }
        return low < records.count && records[low].source.offset == offset ? records[low] : nil
    }
}

public extension LogReader {
    static func detail(_ record: IndexedLogRecord, snapshot: LogSnapshot) throws -> EventDetail {
        try Task.checkCancellation()
        let raw = try sourceText(record.source, snapshot: snapshot)
        let first = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        var body = raw
        if let match = header.firstMatch(in: first, range: NSRange(first.startIndex..., in: first)),
           let range = Range(match.range(at: 5), in: first) {
            body = String(first[range])
            if let newline = raw.firstIndex(of: "\n") { body += String(raw[newline...]) }
        }
        let structured: String
        if let range = body.range(of: " — body: "),
           let object = try? JSONSerialization.jsonObject(with: Data(body[range.upperBound...].utf8), options: [.fragmentsAllowed]) {
            structured = pretty(object)
        } else if let object = try? JSONSerialization.jsonObject(with: Data(body.utf8), options: [.fragmentsAllowed]) {
            structured = pretty(object)
        } else {
            var fields: [String: Any] = ["timestamp": record.timestamp, "level": record.level,
                                       "logger": record.logger, "context": record.context, "body": body]
            if let id = record.requestID { fields["request_id"] = id }
            structured = pretty(fields)
        }
        return EventDetail(readable: body, structured: structured, raw: raw, tree: try StructuredValue.parse(structured))
    }

    /// Full source search, including records that produce no execution event.
    static func searchRecords(_ query: String, snapshot: LogSnapshot, records: [IndexedLogRecord]? = nil, limit: Int = 200) throws -> RecordSearchResults {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return RecordSearchResults(hits: [], limited: false) }
        var hits: [RecordSearchHit] = []
        for record in records ?? snapshot.records {
            try Task.checkCancellation()
            let match: String? = try autoreleasepool {
                let raw = try sourceText(record.source, snapshot: snapshot)
                guard let range = raw.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
                let start = raw.index(range.lowerBound, offsetBy: -50, limitedBy: raw.startIndex) ?? raw.startIndex
                return preview(String(raw[start...].prefix(260)), limit: 240)
            }
            if let match {
                if hits.count == limit { return RecordSearchResults(hits: hits, limited: true) }
                hits.append(RecordSearchHit(record: record, preview: match))
            }
        }
        return RecordSearchResults(hits: hits, limited: false)
    }
}
