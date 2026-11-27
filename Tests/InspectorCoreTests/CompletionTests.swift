import XCTest
@testable import InspectorCore

final class CompletionTests: XCTestCase {
    func line(_ body: String, _ ms: Int, _ logger: String = "omlx.scheduler", _ level: String = "DEBUG") -> String {
        String(format: "2026-11-21 10:00:%02d,%03d - %@ - %@ - [-] - %@\n", ms / 1000, ms % 1000, logger, level, body)
    }
    func request(_ id: String = "a", _ ms: Int = 0) -> String {
        line("Incoming POST /v1/chat/completions — body: {\"model\":\"test\",\"messages\":[{\"role\":\"user\",\"content\":\"\(id)\"}],\"tools\":[]}", ms, "omlx.server", "TRACE")
    }
    func execution(_ id: String = "a", _ start: Int = 100) -> String {
        line("Added request \(id) with 100 prompt tokens", start) + line("Request \(id) finished: stop, 12 tokens", start + 900) + line("Request \(id) generated text:\n<tool_call>terminal</tool_call>", start + 900, "omlx.scheduler", "TRACE")
    }
    func info(_ reason: String? = "tool_calls", _ ms: Int = 1010) -> String {
        line("Chat completion: model=test, 12 tokens in 1.00s (12.0 tok/s), prompt: 100" + (reason.map { ", finish_reason=\($0)" } ?? "") + ", max_tokens=1000", ms, "omlx.server", "INFO")
    }
    func temp(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("completion-\(UUID()).log")
        try Data(text.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func append(_ text: String, _ url: URL) throws {
        let h = try FileHandle(forWritingTo: url); defer { try? h.close() }
        try h.seekToEnd(); try h.write(contentsOf: Data(text.utf8))
    }
    func requests(_ s: LogSnapshot) -> [InspectorEvent] { s.turns.flatMap(\.events).filter { $0.kind == .request } }

    func testRejectedCompletionsPreserveUnattributedEvidence() throws {
        let malformed = info().replacingOccurrences(of: "12 tokens", with: "bad tokens")
        let overlap = request() + execution() + request("b", 1005) + info() + execution("b", 1100) + info("stop", 2015)
        let cases = [info(), request() + execution() + malformed,
                     request() + execution() + info().replacingOccurrences(of: "model=test", with: "model=other"), overlap]
        for text in cases {
            let snapshot = try LogReader.load(temp(text))
            let diagnostics = snapshot.turns.filter { $0.group == 0 }.flatMap(\.events)
            XCTAssertFalse(snapshot.warnings.isEmpty)
            XCTAssertEqual(diagnostics.count, text.components(separatedBy: "Chat completion:").count - 1)
            XCTAssertTrue(requests(snapshot).allSatisfy { $0.completion == nil })
            XCTAssertTrue(snapshot.turns.filter { $0.group != 0 }.flatMap(\.events).allSatisfy { $0.kind != .diagnostic })
            for event in diagnostics {
                XCTAssertEqual(event.kind, .diagnostic)
                XCTAssertNil(event.requestID); XCTAssertNil(event.completion)
                XCTAssertTrue(event.note.contains("no request association or outcome is inferred"))
                let detail = try LogReader.detail(event, snapshot: snapshot)
                XCTAssertTrue(detail.raw.contains("Chat completion:"))
                XCTAssertEqual(detail.raw, detail.structured)
            }
        }
    }
    func testRejectedProvisionalCompletionDoesNotDuplicateAndRemainsSearchable() throws {
        let url = try temp(info()); var index = LogIndex(url: url)
        let first = try XCTUnwrap(index.refresh()?.snapshot)
        let event = try XCTUnwrap(first.turns.first?.events.first)
        try append(line("tick", 2000, "omlx.cache"), url)
        let next = try XCTUnwrap(index.refresh()?.snapshot)
        XCTAssertEqual(next.turns.flatMap(\.events).map(\.id), [event.id])
        XCTAssertEqual(try LogReader.search("finish_reason=tool_calls", snapshot: next).hits.count, 1)
        XCTAssertTrue(DisplayBoundary(snapshot: first).applying(to: next).turns.isEmpty)
        XCTAssertEqual(try LogReader.detail(event, snapshot: next).raw, info())
        let changed = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "model=test", with: "model=else")
        try Data((changed + line("later", 3000, "omlx.cache")).utf8).write(to: url)
        XCTAssertThrowsError(try LogReader.detail(event, snapshot: next))
    }

    func cancellationStart(_ id: String = "a", _ ms: Int = 200) -> String {
        line("[vlm_stream_generate] Aborting request \(id)", ms, "omlx.engine.vlm", "INFO")
    }
    func cleanup(_ id: String = "a", _ ms: Int = 6000) -> String {
        line("Reaped 1 orphaned output collector(s) after disconnect: ['\(id)']", ms, "omlx.engine_core", "DEBUG")
    }
    func cancelledPrefix() -> String {
        request() + line("Added request a with 500 prompt tokens", 100) + cancellationStart()
    }
    func testConfirmedCancellationRecoversAfterAnOverlappingTitleRequest() throws {
        let text = cancelledPrefix() + line("Enqueued deferred abort for request a", 210)
            + request("title", 300) + execution("title", 400) + info("stop", 1310)
            + cleanup() + request("review", 7000) + execution("review", 7100) + info("stop", 8010)
        let snapshot = try LogReader.load(temp(text)), events = requests(snapshot)
        XCTAssertEqual(events.count, 3)
        XCTAssertNil(events[0].completion); XCTAssertNil(events[1].completion)
        XCTAssertEqual(events[2].requestID, "review")
        XCTAssertEqual(events[2].completion?.finishReason, "stop")
        XCTAssertEqual(events[2].completion?.promptTokens, 100)
        let diagnostic = try XCTUnwrap(snapshot.turns.flatMap(\.events).first { $0.title == "Canceled request cleanup" })
        XCTAssertTrue(try LogReader.detail(diagnostic, snapshot: snapshot).raw.contains("Reaped 1"))
        XCTAssertTrue(events[0].note.contains("no server finish reason or successful completion is inferred"))
    }
    func testAbortIntentAloneAndUnmatchedCleanupCannotCloseAnIncomingLifetime() throws {
        for terminal in ["", line("Enqueued deferred abort for request a", 250), cleanup("unknown"),
                         cleanup().replacingOccurrences(of: "Reaped 1", with: "Reaped 2"),
                         cleanup().replacingOccurrences(of: "omlx.engine_core", with: "other.logger")] {
            let snapshot = try LogReader.load(temp(cancelledPrefix() + terminal + request("next", 7000) + execution("next", 7100) + info("stop", 8010)))
            XCTAssertTrue(requests(snapshot).allSatisfy { $0.completion == nil })
        }
        // Scheduler abort alone does not prove the HTTP generator closed without a summary.
        let snapshot = try LogReader.load(temp(request() + line("Added request a with 500 prompt tokens", 100)
            + line("Aborted request a", 300) + request("next", 7000) + execution("next", 7100) + info("stop", 8010)))
        XCTAssertNil(requests(snapshot).last?.completion)
    }
    func testDuplicateCancellationCleanupDoesNotConsumeTheNextRequest() throws {
        let text = cancelledPrefix() + line("Aborted request a", 300)
            + request("next", 7000) + line("Added request next with 100 prompt tokens", 7100)
            + cleanup("a", 7200) + line("Aborted request a", 7300)
            + line("Request next finished: stop, 12 tokens", 8000)
            + line("Request next generated text:\nDone", 8000, "omlx.scheduler", "TRACE") + info("stop", 8010)
        let snapshot = try LogReader.load(temp(text))
        XCTAssertEqual(requests(snapshot).last?.completion?.finishReason, "stop")
        XCTAssertEqual(snapshot.turns.flatMap(\.events).filter { $0.title == "Canceled request cleanup" }.count, 1)
    }
    func testLateCancellationAfterNormalCompletionDoesNotCloseAnotherRequest() throws {
        let text = request() + execution() + info() + request("next", 2000)
            + cancellationStart("a", 2050) + cleanup("a", 2060) + execution("next", 2100) + info("stop", 3010)
        let snapshot = try LogReader.load(temp(text))
        XCTAssertEqual(requests(snapshot).map { $0.completion?.finishReason }, ["tool_calls", "stop"])
    }
    func testPotentialSummaryOfCanceledRequestPreventsDoubleRetirement() throws {
        // An unframed/malformed summary could have closed any active HTTP lifetime.
        for summary in [info().replacingOccurrences(of: "prompt: 100", with: "prompt: 500"),
                        info().replacingOccurrences(of: "12 tokens", with: "bad tokens")] {
            let text = cancelledPrefix() + request("other", 300) + summary + cleanup()
                + request("next", 7000) + execution("next", 7100) + info("stop", 8010)
            let snapshot = try LogReader.load(temp(text))
            XCTAssertTrue(requests(snapshot).allSatisfy { $0.completion == nil })
            XCTAssertTrue(snapshot.warnings.contains { $0.contains("could not be uniquely established") })
        }
    }
    func testCancellationRecoveryIsEquivalentAcrossPartialLiveUpdates() throws {
        let url = try temp(cancelledPrefix()); var index = LogIndex(url: url)
        _ = try index.refresh()
        let terminal = cleanup()
        let split = terminal.index(terminal.startIndex, offsetBy: 65)
        try append(String(terminal[..<split]), url)
        XCTAssertTrue(try XCTUnwrap(index.refresh()).snapshot.hasPartialRecord)
        try append(String(terminal[split...]), url)
        let cleared = try XCTUnwrap(index.refresh()).snapshot
        let boundary = DisplayBoundary(snapshot: cleared)
        try append(request("review", 7000) + execution("review", 7100) + info("stop", 8010), url)
        let live = try XCTUnwrap(index.refresh()).snapshot, full = try LogReader.load(url)
        XCTAssertEqual(requests(live).last?.completion, requests(full).last?.completion)
        XCTAssertEqual(requests(live).last?.completion?.finishReason, "stop")
        XCTAssertEqual(boundary.applying(to: live).requestCount, 1)
        XCTAssertEqual(live.turns.flatMap(\.events).map(\.id), full.turns.flatMap(\.events).map(\.id))
    }

    func testReportedReasonOverridesNeitherSourceNorSchedulerAndAddsNoEvents() throws {
        let s = try LogReader.load(temp(request() + execution() + info()))
        let e = try XCTUnwrap(requests(s).first), c = try XCTUnwrap(e.completion)
        XCTAssertEqual(c.finishReason, "tool_calls"); XCTAssertEqual(c.label, "Tool calls")
        XCTAssertEqual(c.status, "Completed"); XCTAssertEqual(c.promptTokens, 100)
        XCTAssertEqual(c.duration, 1); XCTAssertEqual(e.metrics?.elapsedSeconds ?? 0, 0.9, accuracy: 0.001)
        XCTAssertEqual(s.turns.flatMap(\.events).count, 3)
        XCTAssertEqual(s.turns.flatMap(\.events).first { $0.kind == .output }?.completion, c)
        XCTAssertEqual(s.turns[0].timelineCycles(showContext: false).last?.completion, c)
        let d = try LogReader.detail(e, snapshot: s)
        XCTAssertTrue(d.raw.contains("Incoming POST")); XCTAssertFalse(d.raw.contains("Chat completion:"))
        XCTAssertTrue(d.completionRaw?.contains("finish_reason=tool_calls") == true)
        XCTAssertTrue(d.structured.contains("messages")); XCTAssertFalse(d.structured.contains("finish_reason"))
        XCTAssertTrue(d.readable.contains("Scheduler elapsed: 0.900 s"))
        XCTAssertTrue(d.readable.contains("Inference duration: 1.00 s"))
        XCTAssertTrue(d.readable.contains("Inferred association")); XCTAssertTrue(d.readable.contains("Tool execution: not established"))
        XCTAssertTrue(e.compactSummary.contains("100 prompt tokens"))
    }
    func testFinishLabelsAndAbsentReason() throws {
        for (reason, label) in [("stop", "Stop"), ("length", "Length limit"), ("custom_reason", "Custom Reason"), ("content_filter", "Content filter")] {
            let s = try LogReader.load(temp(request() + execution() + info(reason)))
            XCTAssertEqual(requests(s)[0].completion?.label, label)
        }
        let s = try LogReader.load(temp(request() + execution() + info(nil)))
        XCTAssertNotNil(requests(s)[0].completion)
        XCTAssertNil(requests(s)[0].completion?.finishReason)
        XCTAssertEqual(requests(s)[0].completion?.label, "Finish unavailable")
        XCTAssertEqual(requests(s)[0].completion?.status, "Completion reported · outcome unspecified")
    }
    func testMissingAndMalformedCompletionNeverInventFinishReason() throws {
        for tail in ["", info().replacingOccurrences(of: "12 tokens", with: "bad tokens")] {
            let s = try LogReader.load(temp(request() + execution() + tail))
            let e = requests(s)[0]
            XCTAssertNil(e.completion)
            let d = try LogReader.detail(e, snapshot: s)
            XCTAssertTrue(d.readable.contains("Finish reason: unavailable"))
            XCTAssertTrue(d.readable.contains("Completion status: unverified"))
            XCTAssertTrue(e.compactSummary.contains("100 prompt tokens"))
        }
        XCTAssertEqual(try LogReader.load(temp(info())).requestCount, 0)
    }
    func testDisagreeingEvidenceAndLateCompletionAreRejected() throws {
        for tail in [info().replacingOccurrences(of: "model=test", with: "model=other"),
                     info().replacingOccurrences(of: "prompt: 100", with: "prompt: 101"),
                     info().replacingOccurrences(of: "12 tokens", with: "13 tokens"),
                     info().replacingOccurrences(of: "1.00s", with: "0.10s"),
                     info().replacingOccurrences(of: "1.00s", with: "9.00s"), info("stop", 8000)] {
            let s = try LogReader.load(temp(request() + execution() + tail))
            XCTAssertNil(requests(s)[0].completion)
            XCTAssertFalse(s.warnings.isEmpty)
        }
    }
    func testOverlappingRequestsAndDelayedSummariesStayAmbiguousThenRecover() throws {
        let cases = [
            request() + line("Added request a with 100 prompt tokens", 100) + request("b", 200) + execution("b", 300) + line("Request a finished: stop, 12 tokens", 1300) + line("Request a generated text:\ntext", 1300, "omlx.scheduler", "TRACE") + info("stop", 1310) + info("stop", 1320),
            request() + execution() + request("b", 1005) + info() + execution("b", 1100) + info("stop", 2015)
        ]
        for prefix in cases {
            let s = try LogReader.load(temp(prefix + request("c", 3000) + execution("c", 3100) + info("stop", 4010)))
            XCTAssertEqual(requests(s).count, 3)
            XCTAssertNil(requests(s)[0].completion); XCTAssertNil(requests(s)[1].completion)
            XCTAssertEqual(requests(s)[2].completion?.finishReason, "stop")
        }
    }
    func testMissingSummaryDoesNotShiftLaterAssociations() throws {
        let s = try LogReader.load(temp(request() + execution() + request("b", 3000) + execution("b", 3100) + info("stop", 4010)))
        XCTAssertEqual(requests(s).count, 2)
        XCTAssertTrue(requests(s).allSatisfy { $0.completion == nil })
    }
    func testConcurrentAdmissionsKeepOutputsWithTheirRequestsWithoutGuessingCompletion() throws {
        let text = request("a") + line("Added request a with 100 prompt tokens", 100)
            + request("b", 200) + line("Added request b with 100 prompt tokens", 300)
            + line("Request b finished: stop, 12 tokens", 1000)
            + line("Request b generated text:\nB output", 1000, "omlx.scheduler", "TRACE") + info("stop", 1010)
            + line("Request a finished: stop, 12 tokens", 1500)
            + line("Request a generated text:\nA output", 1500, "omlx.scheduler", "TRACE") + info("stop", 1510)
        let s = try LogReader.load(temp(text))
        XCTAssertEqual(requests(s).map(\.requestID), ["a", "b"])
        XCTAssertTrue(requests(s).allSatisfy { $0.completion == nil })
        XCTAssertFalse(s.turns.contains { $0.title == "Unlinked model output" })
        for turn in s.turns where turn.group != 0 {
            XCTAssertEqual(turn.events.first { $0.kind == .request }?.requestID, turn.events.first { $0.kind == .output }?.requestID)
        }
    }
    func testUnattributedActiveRequestBlocksNewAdmissionUntilItFinishes() throws {
        let text = request("a") + request("b", 50) + line("Added request a with 100 prompt tokens", 100)
            + request("c", 200) + line("Added request c with 100 prompt tokens", 300)
            + line("Request c generated text:\nC output", 400, "omlx.scheduler", "TRACE")
        let s = try LogReader.load(temp(text))
        XCTAssertTrue(requests(s).allSatisfy { $0.requestID == nil })
        XCTAssertTrue(s.turns.contains { $0.title == "Unlinked model output" })
    }
    func testCompletionNavigationUsesTheInfoRecordRatherThanIncomingBody() throws {
        let s = try LogReader.load(temp(request() + execution() + info()))
        let event = try XCTUnwrap(requests(s).first)
        let original = try XCTUnwrap(s.record(containing: event))
        let completion = try XCTUnwrap(s.record(containing: event, completion: true))
        XCTAssertNotEqual(original.id, completion.id)
        XCTAssertEqual(completion.source, event.completion?.source)
        XCTAssertEqual(try LogReader.detail(completion, snapshot: s).raw, info())
    }
    func testDuplicateCompletionDoesNotReassign() throws {
        let s = try LogReader.load(temp(request() + execution() + info() + info("stop", 1020)))
        XCTAssertEqual(requests(s)[0].completion?.finishReason, "tool_calls")
    }
    func testIncrementalPartialAndProvisionalCompletion() throws {
        let url = try temp(request() + execution()); var index = LogIndex(url: url)
        let first = try XCTUnwrap(index.refresh()?.snapshot), id = requests(first)[0].id
        let record = info(), split = record.index(record.startIndex, offsetBy: 100)
        try append(String(record[..<split]), url)
        let partial = try XCTUnwrap(index.refresh()?.snapshot)
        XCTAssertNil(requests(partial)[0].completion)
        try append(String(record[split...]), url)
        let provisional = try XCTUnwrap(index.refresh()?.snapshot)
        XCTAssertEqual(requests(provisional)[0].completion?.finishReason, "tool_calls")
        try append(line("tick", 1020, "omlx.cache"), url)
        let committed = try XCTUnwrap(index.refresh()?.snapshot)
        XCTAssertEqual(requests(committed)[0].id, id)
        XCTAssertEqual(requests(committed)[0].completion, requests(provisional)[0].completion)
        XCTAssertEqual(requests(committed)[0].completion, requests(try LogReader.load(url))[0].completion)
        XCTAssertNil(try index.refresh())
    }
    func testCompletionSourceDigestIsVerifiedIndependently() throws {
        let url = try temp(request() + execution() + info())
        let s = try LogReader.load(url), e = requests(s)[0]
        let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "finish_reason=tool_calls", with: "finish_reason=bad__calls")
        try Data((text + line("appended", 1020)).utf8).write(to: url, options: [])
        XCTAssertNoThrow(try LogReader.sourceText(e.evidence.source, snapshot: s))
        XCTAssertThrowsError(try LogReader.detail(e, snapshot: s))
    }
}
