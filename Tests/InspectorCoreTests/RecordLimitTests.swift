import XCTest
@testable import InspectorCore

final class RecordLimitTests: XCTestCase {
    func testOversizedRecordReportsInitialLoadVersusRetainedIndex() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("record-limit-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let initial = "2026-11-21 10:00:00,000 - omlx.server - TRACE - [-] - Incoming POST /v1/chat/completions — body: {\"messages\":[{\"role\":\"user\",\"content\":\"Preserve this request\"}]}\n"
        try Data(initial.utf8).write(to: url)
        var index = LogIndex(url: url)
        let before = try XCTUnwrap(index.refresh()?.snapshot), bytesRead = index.bytesRead
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("2026-11-21 10:00:01,000 - omlx.scheduler - TRACE - [-] - Request huge generated text:\n".utf8))
        let block = Data((String(repeating: "x", count: 65535) + "\n").utf8)
        for _ in 0...1024 { try handle.write(contentsOf: block) }
        try handle.close()
        let size = try LogReader.metadata(url).0
        XCTAssertThrowsError(try LogReader.load(url)) { error in
            guard case InspectorError.recordTooLarge(let retained) = error else { return XCTFail("Expected typed record limit error") }
            XCTAssertFalse(retained)
            XCTAssertTrue(error.localizedDescription.contains("No partial index was opened"))
            XCTAssertFalse(error.localizedDescription.contains("Monitoring paused"))
        }
        XCTAssertThrowsError(try index.refresh()) { error in
            guard case InspectorError.recordTooLarge(let retained) = error else { return XCTFail("Expected typed record limit error") }
            XCTAssertTrue(retained)
            XCTAssertTrue(error.localizedDescription.contains("Monitoring paused"))
            XCTAssertTrue(error.localizedDescription.contains("Previously indexed evidence remains available"))
        }
        XCTAssertEqual(index.bytesRead, bytesRead)
        XCTAssertEqual(try LogReader.metadata(url).0, size)
        let event = try XCTUnwrap(before.turns.flatMap(\.events).first { $0.kind == .request })
        XCTAssertEqual(try LogReader.detail(event, snapshot: before).raw, initial)
    }
}
