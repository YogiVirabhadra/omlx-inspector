import XCTest
@testable import InspectorCore

final class CoreBoundaryTests: XCTestCase {
    func testResultSummaryDecisionTable() {
        let cases: [(String, String)] = [
            (#"{"success":true,"output":"done"}"#, "done"),
            (#"{"exit_code":2}"#, "Reported error · Nonzero exit code or unsuccessful result"),
            (#"{"success":false,"stderr":"first\nlast\n","output":"fallback"}"#, "Reported error · last"),
            (#"{"error":"primary","stderr":"secondary","output":"third"}"#, "Reported error · primary"),
            (#"{"success":false,"output":"fallback"}"#, "Reported error · fallback"),
            ("plain\ntext", "plain text"),
            ("{broken", "{broken")
        ]
        for (input, expected) in cases {
            let summary = ToolResultText.summary(input)
            XCTAssertEqual(summary.text, expected, input)
            XCTAssertEqual(summary.reportsFailure, expected.hasPrefix("Reported error"), input)
            let wrapped =
                "<untrusted_tool_result source=\"fixture\">\nSafety preamble\n\n\(input)\n</untrusted_tool_result>"
            XCTAssertEqual(ToolResultText.payload(wrapped), input)
            XCTAssertEqual(ToolResultText.summary(wrapped).text, expected)
        }
        for malformed in [
            "<untrusted_tool_result source=\"x\">\n\nmissing close",
            "<untrusted_tool_result source=\"x\">no separator</untrusted_tool_result>",
            "ordinary text\n\n</untrusted_tool_result>"
        ] {
            XCTAssertEqual(ToolResultText.payload(malformed), malformed)
        }
    }

    func testDurationRoundingBoundaries() {
        let cases: [(Double, String)] = [
            (59.9, "59.9 s"), (59.96, "1m 0.0s"), (60, "1m 0.0s"), (119.96, "2m 0.0s"), (3599.9, "59m 59.9s"),
            (3599.96, "1h 0m 0.0s"), (3600, "1h 0m 0.0s")
        ]
        for (seconds, expected) in cases {
            let metrics = TurnMetrics(
                peakPromptTokens: nil, contextComplete: false, elapsedSeconds: seconds, hasTerminalCompletion: false)
            XCTAssertEqual(metrics.durationValue, expected, "\(seconds)")
        }
    }

    func testElapsedKeepsSignedSpanAndRejectsInvalidTimestamps() {
        XCTAssertNil(EvidenceBuilder.elapsedSeconds(from: "invalid", to: "2026-11-27 10:00:00,000"))
        XCTAssertNil(EvidenceBuilder.elapsedSeconds(from: "2026-11-27 10:00:00,000", to: "invalid"))
        XCTAssertEqual(
            EvidenceBuilder.elapsedSeconds(from: "2026-11-27 10:00:01,000", to: "2026-11-27 10:00:00,000"), -1)
    }

    func testTimeOfDay() {
        XCTAssertEqual(LogTimestamp.timeOfDay("2026-11-27 10:04:59,123"), "10:04:59")
        XCTAssertEqual(LogTimestamp.timeOfDay("2026-11-27 10:04:59,123", includingSeconds: false), "10:04")
        XCTAssertEqual(LogTimestamp.timeOfDay(""), "")
    }

    func testProblemLevels() {
        for level in ["WARNING", "ERROR", "CRITICAL"] { XCTAssertTrue(LogGrammar.problemLevels.contains(level)) }
        for level in ["TRACE", "DEBUG", "INFO", "warning"] { XCTAssertFalse(LogGrammar.problemLevels.contains(level)) }
    }
}
