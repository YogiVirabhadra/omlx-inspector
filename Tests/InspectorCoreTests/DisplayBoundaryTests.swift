import XCTest
@testable import InspectorCore

final class DisplayBoundaryTests: XCTestCase {
    func event(_ id: String, offset: UInt64 = 0) -> InspectorEvent {
        InspectorEvent(id: id, kind: .request, title: "Request", summary: "", timestamp: "2026-11-21 10:00:00,000", note: "",
                       evidence: Evidence(source: SourceRef(offset: offset, length: 10, line: 1, endLine: 1, digest: id)))
    }
    func snapshot(_ events: [InspectorEvent]) -> LogSnapshot {
        LogSnapshot(url: URL(fileURLWithPath: "/unused"), size: 100, inode: 1, modified: .distantPast,
                    turns: [InspectorTurn(id: "turn", title: "User turn", group: 1, observed: "", events: events)],
                    recordCount: events.count, warnings: [], generation: "original")
    }
    func testClearHidesExistingEvidenceWithoutChangingCanonicalHistory() {
        let original = snapshot([event("a"), event("b", offset: 20)])
        let boundary = DisplayBoundary(snapshot: original)
        XCTAssertTrue(boundary.applying(to: original).turns.isEmpty)
        XCTAssertEqual(original.requestCount, 2)
        XCTAssertEqual(original.turns[0].events.map(\.id), ["a", "b"])
        var updated = original; updated.turns[0].events.append(event("c", offset: 100))
        XCTAssertEqual(boundary.applying(to: updated).turns[0].events.map(\.id), ["c"])
        XCTAssertEqual(updated.turns[0].timelineCycles(showContext: false).last?.number, 3)
        XCTAssertEqual(updated.turns[0].events.count, 3)
        XCTAssertTrue(DisplayBoundary(snapshot: updated).applying(to: updated).turns.isEmpty)
    }
    func testExistingRecordUpdatesRemainVisibleAfterClear() {
        let original = snapshot([event("a")]), boundary = DisplayBoundary(snapshot: original)
        var changed = event("a")
        changed.metrics = RequestMetrics(promptTokens: 50)
        XCTAssertTrue(boundary.includes(changed, generation: original.generation))
        changed = event("a"); changed.evidence.source.length = 20; changed.evidence.source.digest = "grown output"
        XCTAssertTrue(boundary.includes(changed, generation: original.generation))
        changed = event("a"); changed.linkedEvent = "new result"
        XCTAssertTrue(boundary.includes(changed, generation: original.generation))
        changed = event("a")
        changed.completion = InferenceCompletion(model: "test", promptTokens: 50, generatedTokens: 12, duration: 1, finishReason: "stop", source: changed.evidence.source, timestamp: "2026-11-21 10:00:01,000")
        XCTAssertTrue(boundary.includes(changed, generation: original.generation))
        changed = event("a"); changed.note += "Display-only interpretation"
        XCTAssertFalse(boundary.includes(changed, generation: original.generation))
    }
    func testRotationDoesNotHideReusedOffsetsOrIDs() {
        let original = snapshot([event("a")]), boundary = DisplayBoundary(snapshot: original)
        var rotated = original; rotated.generation = "replacement"
        XCTAssertEqual(boundary.applying(to: rotated).requestCount, 1)
    }
    func testRealLogEvidenceRemainsInspectableAfterClear() throws {
        guard let path = ProcessInfo.processInfo.environment["INSPECTOR_COMPLETION_LOG"] else { throw XCTSkip("Enable native log checks") }
        let original = try LogReader.load(URL(fileURLWithPath: path)), boundary = DisplayBoundary(snapshot: original)
        XCTAssertTrue(boundary.applying(to: original).turns.isEmpty)
        let request = try XCTUnwrap(original.turns.flatMap(\.events).first { $0.kind == .request })
        let detail = try LogReader.detail(request, snapshot: original)
        XCTAssertTrue(detail.raw.contains("Incoming POST"))
        XCTAssertNotNil(detail.completionRaw)
        XCTAssertNotNil(detail.tree)
        XCTAssertTrue(try LogReader.search("Qwen", snapshot: boundary.applying(to: original)).hits.isEmpty)
        XCTAssertFalse(try LogReader.search("Qwen", snapshot: original).hits.isEmpty)
    }
}
