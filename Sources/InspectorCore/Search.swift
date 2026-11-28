import Foundation

/// An event that matched a search, with a preview around the first match.
public struct SearchHit: Identifiable, Sendable {
    public var id: String { event.id }
    public var turnID: String
    public var turnTitle: String
    public var event: InspectorEvent
    public var preview: String
}
/// Event search results. `limited` is `true` when more matches exist than were returned.
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
                    let text = [event.title, event.toolID ?? "", event.requestID ?? "", detail.structured].joined(
                        separator: "\n")
                    guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
                        return nil
                    }
                    let start =
                        text.index(range.lowerBound, offsetBy: -50, limitedBy: text.startIndex) ?? text.startIndex
                    return TextPreview.singleLine(String(text[start...].prefix(260)), limit: 240)
                }
                if let match {
                    if hits.count == limit { return SearchResults(hits: hits, limited: true) }
                    hits.append(SearchHit(turnID: turn.id, turnTitle: turn.title, event: event, preview: match))
                }
            }
        }
        return SearchResults(hits: hits, limited: false)
    }

    /// Full source search, including records that produce no execution event.
    static func searchRecords(
        _ query: String, snapshot: LogSnapshot, records: RecordList? = nil, limit: Int = 200
    ) throws -> RecordSearchResults {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return RecordSearchResults(hits: [], limited: false) }
        var hits: [RecordSearchHit] = []
        for record in records ?? snapshot.records {
            try Task.checkCancellation()
            let match: String? = try autoreleasepool {
                let raw = try snapshot.verifiedText(of: record.source)
                guard let range = raw.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
                    return nil
                }
                let start = raw.index(range.lowerBound, offsetBy: -50, limitedBy: raw.startIndex) ?? raw.startIndex
                return TextPreview.singleLine(String(raw[start...].prefix(260)), limit: 240)
            }
            if let match {
                if hits.count == limit { return RecordSearchResults(hits: hits, limited: true) }
                hits.append(RecordSearchHit(record: record, preview: match))
            }
        }
        return RecordSearchResults(hits: hits, limited: false)
    }
}
