import XCTest
@testable import InspectorCore

final class TurnMetricsTests: XCTestCase {
    let source = SourceRef(offset: 0, length: 0, line: 1, endLine: 1)
    func request(_ time: String, _ prompt: Int?, finish: String? = nil, end: String? = nil) -> InspectorEvent {
        var e = InspectorEvent(id: time, kind: .request, title: "Request", summary: "", timestamp: time,
                               note: "", evidence: Evidence(source: source), metrics: RequestMetrics(promptTokens: prompt))
        if let end {
            e.completion = InferenceCompletion(model: "test", promptTokens: prompt ?? 0, generatedTokens: 20,
                                                duration: 1, finishReason: finish, source: source, timestamp: end)
        }
        return e
    }
    func turn(_ events: [InspectorEvent]) -> InspectorTurn {
        InspectorTurn(id: "turn", title: "Test", group: 1, observed: events.first?.timestamp ?? "", events: events)
    }
    func testPeakUsesMaximumNotLastAndDurationIncludesGapsAcrossMidnight() {
        let t = turn([
            request("2026-11-20 23:59:00,000", 1000, finish: "tool_calls", end: "2026-11-20 23:59:01,000"),
            request("2026-11-21 00:00:02,000", 900, finish: "stop", end: "2026-11-21 00:00:03,500")
        ])
        XCTAssertEqual(t.metrics.peakPromptTokens, 1000)
        XCTAssertTrue(t.metrics.contextComplete)
        XCTAssertEqual(t.metrics.elapsedSeconds, 63.5)
        XCTAssertEqual(t.metrics.durationValue, "1m 3.5s")
        XCTAssertEqual(t.metrics.durationLabel, "Turn duration")
    }
    func testMissingCountsAndToolCallsAreExplicitlyPartial() {
        let t = turn([
            request("2026-11-21 10:00:00,000", nil),
            request("2026-11-21 10:00:01,000", 900, finish: "tool_calls", end: "2026-11-21 10:00:02,000")
        ])
        XCTAssertEqual(t.metrics.contextLabel, "Peak observed context")
        XCTAssertEqual(t.metrics.peakPromptTokens, 900)
        XCTAssertEqual(t.metrics.durationLabel, "Observed span")
        XCTAssertEqual(t.metrics.elapsedSeconds, 2)
        XCTAssertFalse(t.metrics.hasTerminalCompletion)
        let empty = turn([]).metrics
        XCTAssertEqual(empty.contextValue, "Unavailable")
        XCTAssertEqual(empty.durationValue, "Unavailable")
    }
    func testNewPendingRequestWithdrawsCompletedDurationAndInvalidTimeIsUnavailable() {
        var t = turn([request("2026-11-21 10:00:00,000", 900, finish: "stop", end: "2026-11-21 10:00:01,000")])
        XCTAssertTrue(t.metrics.hasTerminalCompletion)
        t.events.append(request("2026-11-21 10:00:05,000", nil))
        XCTAssertEqual(t.metrics.durationLabel, "Observed span")
        XCTAssertEqual(t.metrics.elapsedSeconds, 5)
        XCTAssertEqual(turn([request("invalid", nil)]).metrics.durationValue, "Unavailable")
    }
    func testNativeQwenAndGemmaTurnTotals() throws {
        guard let qwen = ProcessInfo.processInfo.environment["INSPECTOR_COMPLETION_LOG"],
              let gemma = ProcessInfo.processInfo.environment["INSPECTOR_TEST_LOG"] else { throw XCTSkip("Enable native log checks") }
        let q = try XCTUnwrap(LogReader.load(URL(fileURLWithPath: qwen)).turns.first { $0.requests == 9 })
        XCTAssertEqual(q.metrics.peakPromptTokens, 95895)
        XCTAssertEqual(q.metrics.elapsedSeconds ?? 0, 431.905, accuracy: 0.001)
        XCTAssertEqual(q.metrics.durationValue, "7m 11.9s")
        XCTAssertTrue(q.metrics.hasTerminalCompletion)
        let g = try XCTUnwrap(LogReader.load(URL(fileURLWithPath: gemma)).turns.first { $0.title == "That time is very, very, incorrect. Can you check again?" })
        XCTAssertEqual(g.metrics.peakPromptTokens, 15214)
        XCTAssertEqual(g.metrics.elapsedSeconds ?? 0, 2.354, accuracy: 0.001)
        XCTAssertEqual(g.metrics.durationValue, "2.4 s")
    }
}
