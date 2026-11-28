import XCTest
@testable import InspectorCore

final class InspectorTests: XCTestCase {
    func line(_ text: String, logger: String = "omlx.server", level: String = "TRACE") -> String {
        "2026-11-20 15:12:07,890 - \(logger) - \(level) - [-] - \(text)\n"
    }
    func request(_ messages: [[String: Any]]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: ["model": "test-model", "messages": messages, "tools": []], options: [.sortedKeys])
        return line("Incoming POST /v1/chat/completions — body: " + String(decoding: data, as: UTF8.self))
    }
    func temp(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    var initial: [[String: Any]] {
        [["role": "system", "content": "Instructions"], ["role": "user", "content": "Check the date"]]
    }
    func testPrefixHistoryAndExactToolResultLink() throws {
        let next =
            initial + [
                [
                    "role": "assistant", "content": NSNull(),
                    "tool_calls": [
                        [
                            "id": "call-1", "type": "function",
                            "function": ["name": "terminal", "arguments": "{\"command\":\"date\"}"]
                        ]
                    ]
                ], ["role": "tool", "tool_call_id": "call-1", "content": "Friday"]
            ]
        let url = try temp(request(initial) + request(next))
        let s = try LogReader.load(url)
        let events = s.turns.flatMap(\.events)
        XCTAssertEqual(s.turns.count, 1)
        XCTAssertEqual(s.requestCount, 2)
        XCTAssertEqual(s.callCount, 1)
        XCTAssertEqual(events.filter { $0.kind == .user }.count, 1)
        let call = try XCTUnwrap(events.first { $0.kind == .call })
        let result = try XCTUnwrap(events.first { $0.kind == .result })
        XCTAssertEqual(call.linkedEvent, result.id)
        XCTAssertEqual(result.linkedEvent, call.id)
        XCTAssertTrue(try LogReader.detail(call, snapshot: s).readable.contains("date"))
        XCTAssertEqual(try LogReader.detail(result, snapshot: s).readable, "Friday")
    }
    func testIdenticalPromptDoesNotMergeIndependentStarts() throws {
        let s = try LogReader.load(temp(request(initial) + request(initial)))
        XCTAssertEqual(s.turns.count, 2)
        XCTAssertNotEqual(s.turns[0].group, s.turns[1].group)
    }
    func testOverlappingRequestsRemainUnpaired() throws {
        let text =
            try request(initial) + request(initial)
            + line("Added request a with 10 prompt tokens", logger: "omlx.scheduler", level: "DEBUG")
            + line("Request a generated text:\nHello", logger: "omlx.scheduler")
        let s = try LogReader.load(temp(text))
        XCTAssertTrue(s.turns.contains { $0.title == "Unlinked model output" })
        XCTAssertTrue(s.turns.flatMap(\.events).filter { $0.kind == .request }.allSatisfy { $0.requestID == nil })
    }
    func testMultilineOutputAndTemporalEvidenceLabel() throws {
        let text =
            try request(initial)
            + line("Added request a with 10 prompt tokens", logger: "omlx.scheduler", level: "DEBUG")
            + line(
                "Request a generated text:\n<tool_call>\n{\"name\": \"demo\"}\n</tool_call>", logger: "omlx.scheduler")
        let url = try temp(text)
        let s = try LogReader.load(url)
        let output = try XCTUnwrap(s.turns.flatMap(\.events).first { $0.kind == .output })
        XCTAssertTrue(output.note.contains("inferred"))
        XCTAssertTrue(try LogReader.detail(output, snapshot: s).readable.contains("\n{\"name\""))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
    }
    func testMalformedRequestDoesNotStopLaterValidRecords() throws {
        let s = try LogReader.load(temp(line("Incoming POST /v1/chat/completions — body: {broken}") + request(initial)))
        XCTAssertEqual(s.requestCount, 1)
        XCTAssertFalse(s.warnings.isEmpty)
    }
    func testIncompleteFinalRecordIsNotAcceptedAsRequest() throws {
        let text = try request(initial)
        let s = try LogReader.load(temp(String(text.dropLast())))
        XCTAssertEqual(s.requestCount, 0)
        XCTAssertTrue(s.turns.flatMap(\.events).contains { $0.kind == .diagnostic })
    }
    func testUnmatchedResultIsNotReportedAsSuccess() throws {
        let s = try LogReader.load(
            temp(request(initial + [["role": "tool", "tool_call_id": "missing", "content": "some output"]])))
        let e = try XCTUnwrap(s.turns.flatMap(\.events).first { $0.kind == .result })
        XCTAssertNil(e.linkedEvent)
        XCTAssertTrue(e.title.contains("Unmatched"))
        XCTAssertTrue(e.note.contains("agent-reported"))
    }
    func testLargePayloadAndEscapedHeadersRemainComplete() throws {
        let content =
            String(repeating: "line\n", count: 20000) + line("Request fake generated text:", logger: "omlx.scheduler")
        let s = try LogReader.load(temp(request([["role": "user", "content": content]])))
        let e = try XCTUnwrap(s.turns.flatMap(\.events).first { $0.kind == .user })
        XCTAssertEqual(try LogReader.detail(e, snapshot: s).readable, content)
        XCTAssertEqual(s.recordCount, 1)
    }
    func testTruncationInvalidatesEvidence() throws {
        let url = try temp(request(initial))
        let s = try LogReader.load(url)
        try "short".write(to: url, atomically: false, encoding: .utf8)
        XCTAssertThrowsError(try LogReader.detail(s.turns[0].events[0], snapshot: s))
    }
    func testAppendDoesNotAlterSnapshotEvidence() throws {
        let url = try temp(request(initial))
        let s = try LogReader.load(url)
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data(line("New message").utf8))
        try h.close()
        XCTAssertEqual(try LogReader.detail(s.turns[0].events[0], snapshot: s).readable, "Check the date")
    }
    func testNewUserTurnPreservesConversation() throws {
        let later = initial + [["role": "assistant", "content": "Friday"], ["role": "user", "content": "And tomorrow?"]]
        let s = try LogReader.load(temp(request(initial) + request(later)))
        XCTAssertEqual(s.turns.count, 2)
        XCTAssertEqual(s.turns[0].group, s.turns[1].group)
    }
    func testRewriteFollowedByAppendInvalidatesRecordDigest() throws {
        let original = try request(initial)
        let url = try temp(original)
        let s = try LogReader.load(url)
        let replacement = original.replacingOccurrences(of: "Check the date", with: "Check the time") + line("Appended")
        try replacement.write(to: url, atomically: false, encoding: .utf8)
        XCTAssertThrowsError(try LogReader.detail(s.turns[0].events[0], snapshot: s))
    }
    func testAmbiguousHistoryIsNotMerged() throws {
        let later = initial + [["role": "assistant", "content": "Answer"], ["role": "user", "content": "Follow up"]]
        let s = try LogReader.load(temp(request(initial) + request(initial) + request(later)))
        XCTAssertEqual(Set(s.turns.map(\.group)).count, 3)
    }
    func testReasoningRemainsAvailableButCollapsedInReadable() throws {
        let text =
            try request(initial)
            + line("Added request a with 10 prompt tokens", logger: "omlx.scheduler", level: "DEBUG")
            + line("Request a generated text:\n<think>Internal reasoning</think>Answer", logger: "omlx.scheduler")
        let s = try LogReader.load(temp(text))
        let e = try XCTUnwrap(s.turns.flatMap(\.events).first { $0.kind == .output })
        let d = try LogReader.detail(e, snapshot: s)
        XCTAssertFalse(d.readable.contains("Internal reasoning"))
        XCTAssertTrue(d.structured.contains("Internal reasoning"))
        XCTAssertTrue(d.raw.contains("Internal reasoning"))
    }
    func testWrappedToolErrorSummaryUsesReportedEvidence() throws {
        let content =
            "<untrusted_tool_result source=\"example\">\nSafety preamble.\n\n{\"success\":false,\"stderr\":\"Traceback\\nModuleNotFoundError: example\"}\n</untrusted_tool_result>"
        XCTAssertEqual(ToolResultText.summary(content).text, "Reported error · ModuleNotFoundError: example")
        let s = try LogReader.load(
            temp(request(initial + [["role": "tool", "tool_call_id": "missing", "content": content]])))
        let e = try XCTUnwrap(s.turns.flatMap(\.events).first { $0.kind == .result })
        let d = try LogReader.detail(e, snapshot: s)
        XCTAssertTrue(d.readable.contains("Traceback\nModuleNotFoundError"))
        XCTAssertTrue(d.structured.contains("Safety preamble"))
        XCTAssertTrue(d.readable.contains("wrapper collapsed"))
    }
    func testContinuationCountsAndCycleMembershipPreserveEvidence() throws {
        let history =
            initial + [
                ["role": "assistant", "content": "Earlier answer"], ["role": "user", "content": "Again"],
                ["role": "assistant", "content": "Another answer"], ["role": "user", "content": "Check accurately"]
            ]
        let next =
            history + [
                [
                    "role": "assistant",
                    "tool_calls": [["id": "t1", "function": ["name": "terminal", "arguments": "{}"]]]
                ], ["role": "tool", "tool_call_id": "t1", "content": "Friday"]
            ]
        let text =
            try request(history)
            + line("Added request a with 10 prompt tokens", logger: "omlx.scheduler", level: "DEBUG")
            + line("Request a finished: stop", logger: "omlx.scheduler", level: "DEBUG")
            + line("Request a generated text:\nTool intent", logger: "omlx.scheduler") + request(next)
        let snapshot = try LogReader.load(temp(text))
        let turn = try XCTUnwrap(snapshot.turns.first { $0.requestCount == 2 })
        let requests = turn.events.filter { $0.kind == .request }
        XCTAssertEqual(requests.last?.continuation?.reason, "Continuing after terminal result")
        XCTAssertEqual(requests.last?.continuation?.messageDescription, "2 new messages · 6 previous messages retained")
        let cycles = turn.timelineCycles(showContext: true)
        XCTAssertEqual(cycles.flatMap(\.events).map(\.id), turn.events.map(\.id))
        let first = try XCTUnwrap(cycles.first { $0.number == 1 })
        XCTAssertEqual(first.events.map(\.kind), [.request, .output, .call, .result])
        XCTAssertEqual(first.events[2].linkedEvent, first.events[3].id)
        for e in cycles.flatMap(\.events) { XCTAssertFalse(try LogReader.detail(e, snapshot: snapshot).raw.isEmpty) }
    }
    func testParallelResultsUseActualNamesAndCounts() throws {
        let next =
            initial + [
                [
                    "role": "assistant",
                    "tool_calls": [
                        ["id": "a", "function": ["name": "terminal", "arguments": "{}"]],
                        ["id": "b", "function": ["name": "web_search", "arguments": "{}"]]
                    ]
                ], ["role": "tool", "tool_call_id": "a", "content": "one"],
                ["role": "tool", "tool_call_id": "b", "content": "two"]
            ]
        let snapshot = try LogReader.load(temp(request(initial) + request(next)))
        let request = try XCTUnwrap(snapshot.turns.flatMap(\.events).last { $0.kind == .request })
        XCTAssertEqual(request.continuation?.reason, "Continuing after 2 tool results")
        XCTAssertEqual(request.continuation?.messageDescription, "3 new messages · 2 previous messages retained")
    }
    func testNewUserTurnIsNotDescribedAsToolContinuation() throws {
        let next =
            initial + [
                ["role": "tool", "tool_call_id": "unknown", "content": "old result"],
                ["role": "user", "content": "New question"]
            ]
        let snapshot = try LogReader.load(temp(request(initial) + request(next)))
        let newTurn = try XCTUnwrap(snapshot.turns.last)
        XCTAssertEqual(newTurn.events.last?.continuation?.reason, "Responding to a new user message")
        XCTAssertEqual(newTurn.timelineCycles(showContext: false).last?.number, 1)
        XCTAssertNil(snapshot.turns.first?.events.first { $0.kind == .request }?.continuation?.retainedMessages)
    }

    func testGeneratedOutputContainingRequestSeparatorStaysGeneratedText() throws {
        // Regression: output ending in " — body: {…}" was rendered as a request payload.
        let generated = #"The log line reads — body: {"model":"x","messages":[]}"#
        let s = try LogReader.load(
            temp(line("Request a generated text:\n" + generated, logger: "omlx.scheduler", level: "INFO")))
        let output = try XCTUnwrap(s.turns.flatMap(\.events).first { $0.kind == .output })
        let detail = try LogReader.detail(output, snapshot: s)
        XCTAssertEqual(detail.readable, generated + "\n")
        XCTAssertEqual(detail.structured, generated + "\n")
    }
}
