import XCTest
@testable import InspectorCore

final class InferenceDecisionTests: XCTestCase {
    func record(_ body: String, _ time: String = "01,000", logger: String = "omlx.scheduler", level: String = "DEBUG")
        -> LogRecord
    {
        LogRecord(
            source: SourceRef(offset: 0, length: body.utf8.count, line: 1, endLine: 1),
            timestamp: "2026-11-27 10:00:\(time)", logger: logger, level: level, body: body)
    }
    func incoming(_ time: String = "00,000") -> LogRecord {
        record(
            #"Incoming POST /v1/chat/completions — body: {"model":"test","messages":[{"role":"user","content":"fixture"}]}"#,
            time, logger: "omlx.server", level: "TRACE")
    }
    func ready() throws -> EvidenceBuilder {
        var builder = EvidenceBuilder()
        try builder.consume(incoming())
        try builder.consume(record("Added request a with 100 prompt tokens", "00,100"))
        try builder.consume(record("Request a finished: stop, 12 tokens"))
        try builder.consume(record("Request a generated text:\nhello"))
        return builder
    }
    func summary(
        _ time: String = "01,010", model: String = "test", prompt: Int = 100, tokens: Int = 12,
        duration: String = "1.00"
    ) -> LogRecord {
        record(
            "Chat completion: model=\(model), \(tokens) tokens in \(duration)s (12 tok/s), prompt: \(prompt), finish_reason=stop",
            time, logger: "omlx.server", level: "INFO")
    }
    func testCompletionIsolationDecisionTable() throws {
        let missing =
            "The request, scheduler finish, or generated output needed for completion association is unavailable or ambiguous."
        let overlap = "Overlapping or unresolved request lifetimes prevent a reliable completion association."
        let cases: [(String, (inout EvidenceBuilder) -> Void, String?)] = [
            ("isolated", { _ in }, nil),
            (
                "no lifetime", { $0.completionOpen = 0 },
                "No open incoming request could be associated with this server completion."
            ),
            ("multiple lifetimes", { $0.completionOpen = 2 }, overlap),
            ("earlier overlap", { $0.completionOverlap = true }, overlap),
            ("active", { $0.active.insert("other") }, missing),
            ("pending", { $0.pending.append((0, 0)) }, missing),
            ("no window", { $0.completionWindow = nil }, missing),
            ("no scheduler", { $0.completionWindow?.schedulerID = nil }, missing),
            ("no finish", { $0.completionWindow?.finishedAt = nil }, missing),
            ("no output time", { $0.completionWindow?.outputAt = nil }, missing),
            ("no output event", { $0.completionWindow?.outputEvent = nil }, missing)
        ]
        for (name, mutate, rejection) in cases {
            var builder = try ready()
            mutate(&builder)
            let open = builder.completionOpen
            let wasOverlapped = builder.completionOverlap
            builder.consumeCompletion(summary())
            let events = builder.turns.flatMap(\.events)
            XCTAssertEqual(events.filter { $0.completion != nil }.count, rejection == nil ? 2 : 0, name)
            XCTAssertEqual(builder.completionOpen, max(0, open - 1), name)
            XCTAssertNil(builder.completionWindow, name)
            XCTAssertEqual(builder.completionOverlap, wasOverlapped && open > 1, name)
            if let rejection {
                XCTAssertEqual(
                    builder.warnings, [rejection + " See Log diagnostics for the original INFO record."], name)
                XCTAssertTrue(events.contains { $0.kind == .diagnostic && $0.note.hasPrefix(rejection) }, name)
            } else {
                XCTAssertTrue(builder.warnings.isEmpty, name)
            }
        }
    }
    func testCompletionAgreementBoundaries() throws {
        let cases: [(String, LogRecord, Bool)] = [
            ("same instant", summary("01,000"), true),
            ("five seconds", summary("06,000"), true),
            ("late", summary("06,001"), false),
            ("before output", summary("00,999"), false),
            ("wrong model", summary(model: "other"), false),
            ("wrong prompt", summary(prompt: 101), false),
            ("wrong output", summary(tokens: 13), false),
            ("too long", summary(duration: "1.04"), false),
            ("too short", summary(duration: "0.87"), false),
            ("malformed", record("Chat completion: broken", logger: "omlx.server", level: "INFO"), false)
        ]
        for (name, completion, accepted) in cases {
            var builder = try ready()
            builder.consumeCompletion(completion)
            XCTAssertEqual(builder.turns.flatMap(\.events).contains { $0.completion != nil }, accepted, name)
            XCTAssertEqual(builder.warnings.isEmpty, accepted, name)
            XCTAssertEqual(builder.completionOpen, 0, name)
            XCTAssertNil(builder.completionWindow, name)
        }
        var backwards = try ready()
        backwards.completionWindow?.finishedAt = "2026-11-27 10:00:02,000"
        backwards.consumeCompletion(summary())
        XCTAssertTrue(backwards.turns.flatMap(\.events).allSatisfy { $0.completion == nil })
        var negativeScheduler = EvidenceBuilder()
        try negativeScheduler.consume(incoming())
        try negativeScheduler.consume(record("Added request a with 100 prompt tokens", "02,000"))
        try negativeScheduler.consume(record("Request a finished: stop, 12 tokens", "01,000"))
        XCTAssertNil(negativeScheduler.turns.flatMap(\.events).first { $0.kind == .request }?.metrics?.elapsedSeconds)
    }
    func testCancellationRetirementDecisionTableAndFreshRecovery() throws {
        let cases: [(String, Bool, Bool, Bool, Bool, Int, Bool)] = [
            ("proven", true, true, true, false, 1, true),
            ("duplicate or inactive", false, true, true, false, 1, false),
            ("no engine abort", true, false, true, false, 1, false),
            ("unattributed", true, true, false, false, 1, false),
            ("possibly already completed", true, true, true, true, 1, false),
            ("no open lifetime", true, true, true, false, 0, false),
            ("overlapped", true, true, true, false, 2, true)
        ]
        for (name, active, abort, attributed, uncertain, open, retired) in cases {
            var builder = try ready()
            builder.completionOpen = open
            builder.completionOverlap = open > 1
            if active { builder.active.insert("a") }
            if abort { builder.cancellationStarts["a"] = incoming().source }
            if !attributed { builder.scheduler.removeValue(forKey: "a") }
            if uncertain { builder.uncertainActiveCompletions.insert("a") }
            let cleanup = record("Aborted request a")
            XCTAssertTrue(builder.consumeCancellation(cleanup), name)
            XCTAssertFalse(builder.active.contains("a"), name)
            XCTAssertEqual(builder.completionOpen, open - (retired ? 1 : 0), name)
            if retired { XCTAssertNil(builder.completionWindow, name) }
            XCTAssertEqual(builder.completionOverlap, open > 1, name)
            let diagnostics = builder.turns.flatMap(\.events).filter { $0.kind == .diagnostic }
            XCTAssertEqual(diagnostics.count, active && abort ? 1 : 0, name)
            XCTAssertEqual(builder.warnings.isEmpty, !(active && abort && !retired), name)
            if active && abort {
                XCTAssertTrue(
                    diagnostics[0].note.contains(
                        retired ? "The canceled lifetime was retired" : "could not be uniquely established"), name)
            }
            let after = builder.completionOpen
            XCTAssertTrue(builder.consumeCancellation(cleanup))
            XCTAssertEqual(builder.completionOpen, after, name)
            XCTAssertEqual(
                builder.turns.flatMap(\.events).filter { $0.kind == .diagnostic }.count, diagnostics.count, name)
            if retired && after == 0 {
                try builder.consume(incoming("10,000"))
                try builder.consume(record("Added request b with 100 prompt tokens", "10,100"))
                try builder.consume(record("Request b finished: stop, 12 tokens", "11,000"))
                try builder.consume(record("Request b generated text:\nfresh", "11,000"))
                builder.consumeCompletion(summary("11,010"))
                XCTAssertEqual(builder.turns.flatMap(\.events).filter { $0.completion != nil }.count, 2, name)
            }
        }
    }
}
