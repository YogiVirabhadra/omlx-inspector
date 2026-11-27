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
            evidence = event.evidence; metrics = event.metrics; completion = event.completion
            requestID = event.requestID; linkedEvent = event.linkedEvent
        }
    }
    private let generation: String
    private let revisions: [String: Revision]
    public init(snapshot: LogSnapshot) {
        generation = snapshot.generation
        revisions = Dictionary(snapshot.turns.flatMap(\.events).map { ($0.id, Revision($0)) }, uniquingKeysWith: { _, last in last })
    }
    public func includes(_ event: InspectorEvent, generation: String) -> Bool {
        self.generation != generation || revisions[event.id] != Revision(event)
    }
    public func applying(to snapshot: LogSnapshot) -> LogSnapshot {
        var display = snapshot
        display.turns = snapshot.turns.compactMap { turn in
            var visible = turn
            visible.events = turn.events.filter { includes($0, generation: snapshot.generation) }
            return visible.events.isEmpty ? nil : visible
        }
        return display
    }
}
