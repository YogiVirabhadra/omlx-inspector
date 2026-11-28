import Foundation

/// A view-only boundary: the canonical evidence index continues to reconstruct history.
/// Changed provisional records, scheduler metrics, links, and completions count as new activity.
public struct DisplayBoundary: Sendable {
    private struct Revision: Sendable, Equatable {
        let evidence: Evidence
        let metrics: RequestMetrics?
        let completion: InferenceCompletion?
        let requestID: String?
        let linkedEvent: String?
        init(_ event: InspectorEvent) {
            evidence = event.evidence
            metrics = event.metrics
            completion = event.completion
            requestID = event.requestID
            linkedEvent = event.linkedEvent
        }
    }
    private let generation: String
    private let revisions: [String: Revision]
    private let lastRecord: SourceRef?
    /// Captures everything currently in `snapshot` as already seen.
    public init(snapshot: LogSnapshot) {
        generation = snapshot.generation
        lastRecord = snapshot.records.last?.source
        revisions = Dictionary(
            snapshot.turns.flatMap(\.events).map { ($0.id, Revision($0)) }, uniquingKeysWith: { _, last in last })
    }
    /// Whether an event is new or has changed since the boundary was captured.
    public func includes(_ event: InspectorEvent, generation: String) -> Bool {
        self.generation != generation || revisions[event.id] != Revision(event)
    }
    /// `snapshot` reduced to events and records after the boundary. Turns left empty are removed.
    public func applying(to snapshot: LogSnapshot) -> LogSnapshot {
        var display = snapshot
        if generation == snapshot.generation, let lastRecord {
            // Records are in source order, so only those from the boundary onward can be included.
            let start = snapshot.records.firstIndex(atOrAfter: lastRecord.offset)
            display.records = RecordList(
                snapshot.records[start...].lazy.filter { includes($0, generation: snapshot.generation) })
        }
        display.turns = snapshot.turns.compactMap { turn in
            var visible = turn
            visible.events = turn.events.filter { includes($0, generation: snapshot.generation) }
            return visible.events.isEmpty ? nil : visible
        }
        return display
    }
    /// Whether a record is new, or is the boundary's last record and has since grown.
    public func includes(_ record: IndexedLogRecord, generation: String) -> Bool {
        guard self.generation == generation, let lastRecord else { return true }
        return record.source.offset > lastRecord.offset
            || (record.source.offset == lastRecord.offset && record.source != lastRecord)
    }
}
