import XCTest

@testable import InspectorCore

final class RecordListTests: XCTestCase {
    func record(_ offset: UInt64, logger: String = "omlx.cache") -> IndexedLogRecord {
        IndexedLogRecord(
            LogRecord(
                source: SourceRef(offset: offset, length: 1, line: Int(offset) + 1, endLine: Int(offset) + 1),
                timestamp: "", logger: logger, level: "DEBUG", body: "record \(offset)"))
    }

    func testIndexingAcrossChunkBoundaries() {
        let total = RecordList.chunkSize * 2 + 3
        let list = RecordList((0..<total).map { record(UInt64($0)) })
        XCTAssertEqual(list.count, total)
        for position in [0, RecordList.chunkSize - 1, RecordList.chunkSize, RecordList.chunkSize * 2, total - 1] {
            XCTAssertEqual(list[position].source.offset, UInt64(position))
        }
        XCTAssertEqual(list.last?.source.offset, UInt64(total - 1))
        XCTAssertEqual(Array(list.dropFirst(RecordList.chunkSize).prefix(2)).map(\.source.offset), [4096, 4097])
    }

    func testAppendingToACopyLeavesTheOriginalUnchanged() {
        var original = RecordList((0..<RecordList.chunkSize).map { record(UInt64($0)) })
        var copy = original
        copy.append(record(9_999))
        XCTAssertEqual(original.count, RecordList.chunkSize)
        XCTAssertEqual(copy.count, RecordList.chunkSize + 1)
        XCTAssertEqual(copy.last?.source.offset, 9_999)
        original.append(record(7))
        XCTAssertEqual(original.last?.source.offset, 7)
        XCTAssertEqual(copy.last?.source.offset, 9_999)
    }

    func testEqualityAndOffsetSearch() {
        let list = RecordList([0, 10, 20, 30].map { record($0) })
        XCTAssertEqual(list, RecordList([0, 10, 20, 30].map { record($0) }))
        XCTAssertNotEqual(list, RecordList([0, 10, 20].map { record($0) }))
        XCTAssertEqual(RecordList(), RecordList([IndexedLogRecord]()))
        XCTAssertEqual(list.firstIndex(atOrAfter: 0), 0)
        XCTAssertEqual(list.firstIndex(atOrAfter: 15), 2)
        XCTAssertEqual(list.firstIndex(atOrAfter: 30), 3)
        XCTAssertEqual(list.firstIndex(atOrAfter: 31), 4)
    }

    func testLookupByRecordID() {
        let list = RecordList([0, 10, 20].map { record($0) })
        XCTAssertEqual(list.index(ofRecordID: list[1].id), 1)
        XCTAssertEqual(list.record(withID: "l20")?.source.offset, 20)
        XCTAssertNil(list.index(ofRecordID: "l15"))
        XCTAssertNil(list.index(ofRecordID: "l99"))
        for invalid in ["", "l", "x10", "l-1", "l1x", "m10"] {
            XCTAssertNil(list.index(ofRecordID: invalid), invalid)
        }
    }

    func testSnapshotLoggersIncludeProvisionalRecords() throws {
        let line = { (logger: String, body: String) in "2026-11-26 10:00:00,123 - \(logger) - DEBUG - [-] - \(body)\n" }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loggers-\(UUID()).log")
        try Data((line("omlx.server", "first") + line("omlx.cache", "second")).utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let snapshot = try LogReader.load(url)
        XCTAssertEqual(snapshot.loggers, ["omlx.cache", "omlx.server"])
        XCTAssertEqual(snapshot.loggers, Array(Set(snapshot.records.map(\.logger))).sorted())
    }
}
