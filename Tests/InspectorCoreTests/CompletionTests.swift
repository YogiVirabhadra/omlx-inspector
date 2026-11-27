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
    func testActualFullLogCodeReviewTurnAfterCancellation() throws {
        guard let path = ProcessInfo.processInfo.environment["INSPECTOR_COMPLETION_LOG"] else { throw XCTSkip("Enable native full-log checks") }
        let snapshot = try LogReader.load(URL(fileURLWithPath: path))
        let turn = try XCTUnwrap(snapshot.turns.first { $0.title.hasPrefix("Please do a careful code review of the oMLX Inspector project") })
        let events = turn.events.filter { $0.kind == .request }
        XCTAssertEqual(events.count, 42)
        XCTAssertEqual(events.compactMap(\.completion).count, 42)
        XCTAssertEqual(turn.events.filter { $0.kind == .output }.count, 42)
        XCTAssertEqual(events.dropLast().compactMap { $0.completion?.finishReason }, Array(repeating: "tool_calls", count: 41))
        XCTAssertEqual(events.last?.completion?.finishReason, "stop")
        XCTAssertEqual(turn.metrics.peakPromptTokens, 179590)
        XCTAssertTrue(turn.metrics.contextComplete); XCTAssertTrue(turn.metrics.hasTerminalCompletion)
        XCTAssertEqual(turn.metrics.elapsedSeconds ?? 0, 1710.846, accuracy: 0.001)
        let visible = turn.events.filter { $0.kind != .context }
        XCTAssertEqual(visible.count, 207)
        XCTAssertEqual(turn.timelineCycles(showContext: false).compactMap(\.number), Array(1...42))
        // All page-two events remain accessible, including full final request and completion evidence.
        for event in visible.suffix(7) { XCTAssertFalse(try LogReader.detail(event, snapshot: snapshot, includeTree: false).raw.isEmpty) }
        let final = try XCTUnwrap(events.last)
        let detail = try LogReader.detail(final, snapshot: snapshot)
        XCTAssertNotNil(detail.tree)
        XCTAssertTrue(detail.completionRaw?.contains("finish_reason=stop") == true)
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
    func testActualNovember21NineQwenCompletions() throws {
        guard let path = ProcessInfo.processInfo.environment["INSPECTOR_COMPLETION_LOG"] else { throw XCTSkip("Set INSPECTOR_COMPLETION_LOG to November 21 native log") }
        let start = Date(), s = try LogReader.load(URL(fileURLWithPath: path)), events = requests(s)
        let ids = ["6867a693-9501-4e18-83e7-92df16f69c7f", "320fdaba-5e3e-4b4d-9d4f-5bcec2769741", "e9ca66ed-a466-4351-9a06-2a4566ce885c", "e9cede33-6437-4620-9fbf-c81caeba5012", "05758436-d46d-4ac0-b7ed-e513953fe1d2", "f438a1b1-0dfc-4c07-916d-55d174ade667", "d0cb33a4-d65d-4add-8f80-e593ee760906", "67823df4-db57-45a6-bb8a-f15d24a8e7dd", "b57ea2ba-805b-4372-a762-ca2ad3224645"]
        let prompts = [17606,29960,65129,75448,83772,95114,95349,95528,95895]
        let generated = [282,1168,4946,962,11223,114,99,52,3608]
        let durations = [18.64,23.99,103.12,22.54,185.25,9.08,2.29,1.99,29.36]
        for i in ids.indices {
            let e = try XCTUnwrap(events.first { $0.requestID == ids[i] }), c = try XCTUnwrap(e.completion)
            XCTAssertEqual(c.finishReason, i == 8 ? "stop" : "tool_calls")
            XCTAssertEqual(c.promptTokens, prompts[i]); XCTAssertEqual(c.generatedTokens, generated[i]); XCTAssertEqual(c.duration, durations[i])
            XCTAssertEqual(s.turns.flatMap(\.events).first { $0.kind == .output && $0.requestID == ids[i] }?.completion, c)
            let d = try LogReader.detail(e, snapshot: s)
            XCTAssertTrue(d.completionRaw?.contains("finish_reason=\(c.finishReason!)") == true)
            XCTAssertNotNil(d.tree)
        }
        print("QWEN COMPLETION VERIFICATION: 9 matched, 8 tool_calls + 1 stop, load/details seconds=\(Date().timeIntervalSince(start))")
    }
    func testActualEarlierGemmaCompletionsAndDelta() throws {
        guard let path = ProcessInfo.processInfo.environment["INSPECTOR_TEST_LOG"] else { throw XCTSkip("Set INSPECTOR_TEST_LOG to November 20 native log") }
        let s = try LogReader.load(URL(fileURLWithPath: path))
        let e = try XCTUnwrap(requests(s).first { $0.timestamp.hasPrefix("2026-11-20 15:16:15") })
        XCTAssertEqual(e.completion?.finishReason, "stop")
        XCTAssertEqual(e.completion?.promptTokens, 15214); XCTAssertEqual(e.completion?.duration, 1.02)
        let prior = try XCTUnwrap(requests(s).first { $0.id == e.metrics?.previousRequest })
        XCTAssertEqual(prior.completion?.finishReason, "tool_calls")
        XCTAssertEqual(prior.completion?.promptTokens, 15165); XCTAssertEqual(prior.completion?.duration, 0.99)
        XCTAssertTrue(try LogReader.detail(e, snapshot: s).readable.contains("Prompt-token change: +49"))
    }
}
