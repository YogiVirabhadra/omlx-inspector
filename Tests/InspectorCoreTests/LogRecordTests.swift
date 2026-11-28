import CryptoKit
import XCTest
@testable import InspectorCore

final class LogRecordTests: XCTestCase {
    func line(_ body: String, logger: String = "omlx.cache", level: String = "DEBUG", context: String = "-") -> String {
        "2026-11-26 10:00:00,123 - \(logger) - \(level) - [\(context)] - \(body)\n"
    }
    func request() -> String {
        line(
            "Incoming POST /v1/chat/completions — body: {\"model\":\"test\",\"messages\":[{\"role\":\"user\",\"content\":\"café\"}]}",
            logger: "omlx.server", level: "TRACE")
    }
    func temp(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("records-\(UUID()).log")
        try Data(text.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func append(_ text: String, to url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: Data(text.utf8))
    }
    func testAllRecordsRemainAccessibleIncludingMultilineNoise() throws {
        let noise = line("Cache hit\ncontinuation with café and 🐸", context: "worker-7")
        let text = noise + request() + line("Added request abc-123 with 100 prompt tokens", logger: "omlx.scheduler")
        let s = try LogReader.load(temp(text))
        XCTAssertEqual(s.records.count, s.recordCount)
        XCTAssertEqual(s.records.count, 3)
        XCTAssertEqual(s.records[0].context, "worker-7")
        XCTAssertEqual(s.records[0].source.endLine, 2)
        XCTAssertEqual(s.records[2].requestID, "abc-123")
        XCTAssertEqual(try LogReader.detail(s.records[0], snapshot: s).raw, noise)
        let detail = try LogReader.detail(s.records[0], snapshot: s)
        XCTAssertTrue(detail.structured.contains("worker-7"))
        XCTAssertTrue(detail.tree?.node(at: "/body")?.completeText.contains("🐸") == true)
        XCTAssertEqual(
            try LogReader.detail(s.records[1], snapshot: s).tree?.node(at: "/messages/0/content")?.completeText, "café")
    }
    func testEveryDerivedEventNavigatesToItsExactOriginalRecord() throws {
        let rich = line(
            "Incoming POST /v1/chat/completions — body: {\"model\":\"test\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"},{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"c\",\"function\":{\"name\":\"terminal\",\"arguments\":\"{}\"}}]},{\"role\":\"tool\",\"tool_call_id\":\"c\",\"content\":\"done\"}]}",
            logger: "omlx.server", level: "TRACE")
        let s = try LogReader.load(temp(line("noise") + rich))
        for event in s.turns.flatMap(\.events) {
            XCTAssertEqual(s.record(containing: event)?.source, s.records[1].source)
            XCTAssertEqual(try LogReader.detail(XCTUnwrap(s.record(containing: event)), snapshot: s).raw, rich)
        }
    }
    func testIncrementalRecordsAndClearBoundaryHandleGrowingLastRecord() throws {
        let url = try temp(line("First\npartial body"))
        var index = LogIndex(url: url)
        let initial = try XCTUnwrap(index.refresh()).snapshot
        let boundary = DisplayBoundary(snapshot: initial)
        try append("more body\n" + line("Second") + "2026-11-26", to: url)
        let partial = try XCTUnwrap(index.refresh()).snapshot
        XCTAssertEqual(partial.records.count, 3)
        XCTAssertEqual(partial.records[0].id, initial.records[0].id)
        XCTAssertEqual(boundary.applying(to: partial).records.count, 3)
        XCTAssertTrue(partial.hasPartialRecord)
        try append(" 10:00:00,123 - omlx.cache - INFO - [-] - Third\n", to: url)
        let live = try XCTUnwrap(index.refresh()).snapshot
        let full = try LogReader.load(url)
        XCTAssertEqual(live.records, full.records)
        XCTAssertEqual(live.records.count, 3)
        XCTAssertFalse(live.hasPartialRecord)
        XCTAssertEqual(try LogReader.detail(live.records[2], snapshot: live).readable, "Third\n")
    }
    func testUnchangedRecordsStayHiddenAndNewGenerationShowsAll() throws {
        let url = try temp(line("First"))
        var index = LogIndex(url: url)
        let first = try XCTUnwrap(index.refresh()).snapshot
        let boundary = DisplayBoundary(snapshot: first)
        try append(line("Second"), to: url)
        let next = try XCTUnwrap(index.refresh()).snapshot
        XCTAssertEqual(boundary.applying(to: next).records.map(\.summary), ["Second"])
        try Data(line("Replacement").utf8).write(to: url)
        let reset = try XCTUnwrap(index.refresh())
        XCTAssertTrue(reset.reset)
        XCTAssertEqual(boundary.applying(to: reset.snapshot).records, reset.snapshot.records)
        XCTAssertThrowsError(try LogReader.detail(first.records[0], snapshot: first))
    }
    func testSourceDigestDetectsChangesAndFullSearchIncludesHiddenBody() throws {
        let needle = line(String(repeating: "padding ", count: 100) + "needle 🐸", level: "INFO")
        let url = try temp(line("ordinary") + needle + line("needle second"))
        let s = try LogReader.load(url)
        XCTAssertTrue(s.turns.isEmpty)
        XCTAssertFalse(s.records[1].summary.contains("needle"))
        let results = try LogReader.searchRecords("NEEDLE", snapshot: s)
        XCTAssertEqual(results.hits.count, 2)
        XCTAssertEqual(results.hits[0].record.id, s.records[1].id)
        XCTAssertTrue(try LogReader.searchRecords("needle", snapshot: s, limit: 1).limited)
        XCTAssertEqual(try LogReader.searchRecords("needle", snapshot: s, records: [s.records[1]]).hits.count, 1)
        XCTAssertTrue(try LogReader.searchRecords(" ", snapshot: s).hits.isEmpty)
        try Data(
            (line("ordinary") + needle.replacingOccurrences(of: "padding", with: "changed") + line("needle second")
                + line("extra")).utf8
        ).write(to: url)
        XCTAssertThrowsError(try LogReader.detail(s.records[1], snapshot: s))
    }
    func testMalformedRequestAndGeneratedOutputStillHaveStructuredBody() throws {
        let source = line("Incoming POST /v1/chat/completions — body: {broken", logger: "omlx.server", level: "TRACE")
        let output = line(
            "Request abc generated text:\n<think>reasoning</think>\nanswer", logger: "omlx.scheduler", level: "TRACE")
        let s = try LogReader.load(temp(source + output))
        XCTAssertEqual(s.records.count, 2)
        XCTAssertTrue(
            try LogReader.detail(s.records[0], snapshot: s).tree?.node(at: "/body")?.completeText.contains("{broken")
                == true)
        XCTAssertEqual(s.records[1].requestID, "abc")
        XCTAssertEqual(try LogReader.detail(s.records[1], snapshot: s).raw, output)
    }

    func testLeadingBlankLinesDoNotInvalidateUnframedRecord() throws {
        // Regression: blank lines before the first record were included in the unframed
        // record's digest but not its source range, so its Source view always failed.
        let s = try LogReader.load(temp("\n\nstray text\n" + line("framed")))
        XCTAssertEqual(s.records.count, 2)
        XCTAssertEqual(s.records[0].logger, LogGrammar.unknownLogger)
        XCTAssertEqual(s.records[0].source.line, 3)
        XCTAssertEqual(try LogReader.detail(s.records[0], snapshot: s).raw, "stray text\n")
        XCTAssertEqual(s.records[1].source.line, 4)
        XCTAssertNoThrow(try LogReader.detail(s.records[1], snapshot: s))
    }

    func testLongMultilineRecordKeepsCompleteSourceRange() throws {
        let body = String(repeating: "generated output line\n", count: 20_000)
        let text = line("Request a generated text:\n" + body, logger: "omlx.scheduler", level: "INFO")
        let s = try LogReader.load(temp(text))
        let record = try XCTUnwrap(s.records.first)
        XCTAssertEqual(record.source.length, text.utf8.count)
        XCTAssertEqual(record.source.endLine, 20_002)
        XCTAssertEqual(try LogReader.detail(record, snapshot: s).raw, text)
    }

    func testRecordDigestIsLowercaseHexOfTheExactSourceBytes() throws {
        let text = line("first") + line("second\ncontinued")
        let s = try LogReader.load(temp(text))
        let second = s.records[1].source
        let bytes = Data(text.utf8)[Int(second.offset)..<(Int(second.offset) + second.length)]
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(second.digest, expected)
    }
}
