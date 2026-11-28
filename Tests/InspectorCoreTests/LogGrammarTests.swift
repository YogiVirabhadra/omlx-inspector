import XCTest
@testable import InspectorCore

final class LogGrammarTests: XCTestCase {
    func testEveryPatternHasIndependentCanonicalAndNegativeFixture() {
        let fixtures: [String: (String, [String])] = [
            "header": (
                "2026-11-27 10:00:00,000 - omlx.server - TRACE - [-] - hello",
                ["2026-11-27 10:00:00,000", "omlx.server", "TRACE", "-", "hello"]
            ),
            "incomingRequest": ("Incoming POST /v1/chat/completions — body: {}", []),
            "completionSummary": ("Chat completion: malformed but still closes a lifetime", []),
            "schedulerAdded": ("Added request a with 100 prompt tokens", ["a", "100"]),
            "schedulerFinished": ("Request a finished: stop, 12 tokens", ["a"]),
            "finishedTokens": ("Request a finished: stop, 12 tokens", ["12"]),
            "generatedOutput": ("Request a generated text:\nhello", ["a"]),
            "backgroundProcess": ("[IMPORTANT: Background process job-1 completed", ["job-1"]),
            "completionFields": (
                "Chat completion: model=test, 12 tokens in 1.00s (12 tok/s), prompt: 100, finish_reason=stop",
                ["test", "12", "1.00", "100"]
            ),
            "finishReason": ("model=test, finish_reason=stop", ["stop"]),
            "engineAbort": ("[vlm_stream_generate] Aborting request a", ["a"]),
            "schedulerAbort": ("Aborted request a", ["a"]),
            "orphanCleanup": ("Reaped 1 orphaned output collector(s) after disconnect: ['a']", ["1", "['a']"]),
            "requestID": ("a_1-2", ["a_1-2"]),
            "recordRequestID": ("Request a generated text:", ["a"])
        ]
        XCTAssertEqual(Set(LogGrammar.all.map(\.id)), Set(fixtures.keys))
        XCTAssertEqual(LogGrammar.all.count, fixtures.count, "Stable IDs must be unique")
        for pattern in LogGrammar.all {
            guard let (body, captures) = fixtures[pattern.id] else { return XCTFail(pattern.id) }
            var record = LogRecord(
                source: SourceRef(offset: 0, length: 0, line: 1, endLine: 1), timestamp: "",
                logger: pattern.logger ?? "custom", level: pattern.level ?? "TRACE", body: body)
            XCTAssertEqual(pattern.captures(in: record), captures, pattern.id)
            record.body = "!invalid!"
            XCTAssertNil(pattern.captures(in: record), pattern.id)
            record.body = body
            if pattern.logger != nil {
                record.logger = "wrong.logger"
                XCTAssertNil(pattern.captures(in: record), pattern.id)
                record.logger = pattern.logger!
            }
            record.level = "ERROR"
            if pattern.level != nil {
                XCTAssertNil(pattern.captures(in: record), pattern.id)
            } else {
                XCTAssertEqual(pattern.captures(in: record), captures, pattern.id)
            }
        }
    }
    func testNearMatchesPreserveExistingGrammarBoundaries() {
        XCTAssertNil(LogGrammar.schedulerAdded.captures(in: "Added request a with many prompt tokens"))
        XCTAssertNil(LogGrammar.schedulerAdded.captures(in: "prefix Added request a with 100 prompt tokens"))
        XCTAssertNil(LogGrammar.incomingRequest.captures(in: "Incoming POST /v1/completions — body: {}"))
        XCTAssertNil(LogGrammar.engineAbort.captures(in: "[vlm_stream_generate] Aborting request a trailing"))
        XCTAssertNil(
            LogGrammar.completionFields.captures(
                in: "Chat completion: model=test, x tokens in 1.0s (x tok/s), prompt: 100"))
        // These expressions intentionally accept trailing scheduler details and
        // do not require a finish reason to parse a completion summary.
        XCTAssertEqual(
            LogGrammar.schedulerAdded.captures(in: "Added request a with 100 prompt tokens extra"), ["a", "100"])
        XCTAssertNotNil(
            LogGrammar.completionFields.captures(
                in: "Chat completion: model=test, 12 tokens in 1.0s (12 tok/s), prompt: 100"))
    }
    func testOrphanCleanupRejectsInvalidCountDuplicatesAndIDs() throws {
        for list in [
            "Reaped 2 orphaned output collector(s) after disconnect: ['a']",
            "Reaped 2 orphaned output collector(s) after disconnect: ['a', 'a']",
            "Reaped 1 orphaned output collector(s) after disconnect: ['a.b']"
        ] {
            var builder = EvidenceBuilder()
            builder.active.insert("a")
            builder.completionOpen = 1
            let record = LogRecord(
                source: SourceRef(offset: 0, length: 0, line: 1, endLine: 1), timestamp: "", logger: "omlx.engine_core",
                level: "DEBUG", body: list)
            XCTAssertFalse(builder.consumeCancellation(record), list)
            XCTAssertEqual(builder.active, ["a"])
            XCTAssertEqual(builder.completionOpen, 1)
        }
    }
}
