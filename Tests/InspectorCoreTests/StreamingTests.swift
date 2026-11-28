import XCTest
@testable import InspectorCore

final class StreamingTests: XCTestCase {
    func line(_ text: String, logger: String = "omlx.server", level: String = "TRACE", time: String = "15:12:07,890")
        -> String
    {
        "2026-11-20 \(time) - \(logger) - \(level) - [-] - \(text)\n"
    }
    var messages: [[String: Any]] {
        [["role": "system", "content": "Instructions"], ["role": "user", "content": "Find the café ☕"]]
    }
    func request(_ messages: [[String: Any]], tools: [Any] = [], temperature: Double = 0.5) throws -> String {
        line(
            "Incoming POST /v1/chat/completions — body: "
                + String(
                    decoding: try JSONSerialization.data(
                        withJSONObject: [
                            "model": "test", "messages": messages, "tools": tools, "temperature": temperature
                        ], options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self))
    }
    func temp(_ text: String = "") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "omlx-index-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.log")
        try Data(text.utf8).write(to: url)
        return url
    }
    func append(_ data: Data, to url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: data)
    }
    func testChunkBoundariesUTF8AndIncrementalEquivalence() throws {
        let later = messages + [["role": "assistant", "content": "Réponse 🌎"], ["role": "user", "content": "Again"]]
        let text =
            try request(messages) + line("Added request x with 15 prompt tokens", logger: "omlx.scheduler")
            + line("Request x generated text:\nfirst\nsecond 🌎", logger: "omlx.scheduler") + request(later)
        let url = try temp()
        var index = LogIndex(url: url)
        _ = try index.refresh()
        let bytes = Data(text.utf8)
        var latest: LogSnapshot?
        for start in stride(from: 0, to: bytes.count, by: 17) {
            try append(bytes[start..<min(start + 17, bytes.count)], to: url)
            latest = try index.refresh()?.snapshot
        }
        let full = try LogReader.load(url)
        let incremental = try XCTUnwrap(latest)
        XCTAssertEqual(incremental.recordCount, full.recordCount)
        XCTAssertEqual(incremental.turns.flatMap(\.events).map(\.id), full.turns.flatMap(\.events).map(\.id))
        for (a, b) in zip(incremental.turns.flatMap(\.events), full.turns.flatMap(\.events)) {
            XCTAssertEqual(a.evidence, b.evidence)
            XCTAssertEqual(
                try LogReader.detail(a, snapshot: incremental).raw, try LogReader.detail(b, snapshot: full).raw)
        }
        XCTAssertEqual(index.bytesRead, UInt64(bytes.count))
        XCTAssertNil(try index.refresh())
        XCTAssertEqual(index.bytesRead, UInt64(bytes.count))
    }
    func testProvisionalOutputGrowsWithoutDuplicates() throws {
        let url = try temp(
            request(messages) + line("Added request x with 12 prompt tokens", logger: "omlx.scheduler")
                + line("Request x generated text:\nHello", logger: "omlx.scheduler"))
        var index = LogIndex(url: url)
        let first = try XCTUnwrap(index.refresh()?.snapshot)
        let id = try XCTUnwrap(first.turns.flatMap(\.events).first { $0.kind == .output }?.id)
        try append(Data(" world\n".utf8), to: url)
        let next = try XCTUnwrap(index.refresh()?.snapshot)
        let outputs = next.turns.flatMap(\.events).filter { $0.kind == .output }
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(outputs[0].id, id)
        XCTAssertTrue(try LogReader.detail(outputs[0], snapshot: next).readable.contains("Hello\n world"))
        XCTAssertFalse(
            try LogReader.detail(first.turns.flatMap(\.events).first { $0.kind == .output }!, snapshot: first).raw
                .contains(" world"))
    }
    func testIncompleteNextHeaderDoesNotWithdrawPreviousRequest() throws {
        let url = try temp(request(messages))
        var index = LogIndex(url: url)
        let first = try XCTUnwrap(index.refresh()?.snapshot)
        try append(Data("2026-11-20 ".utf8), to: url)
        let next = try XCTUnwrap(index.refresh()?.snapshot)
        XCTAssertEqual(next.requestCount, first.requestCount)
        XCTAssertTrue(next.hasPartialRecord)
        XCTAssertEqual(next.turns[0].events[0].id, first.turns[0].events[0].id)
    }
    func testRotationCreatesSeparateGenerationAndOldEvidenceStillReadable() throws {
        let url = try temp(request(messages))
        var index = LogIndex(url: url)
        let first = try XCTUnwrap(index.refresh()?.snapshot)
        let rotated = url.appendingPathExtension("1")
        try FileManager.default.moveItem(at: url, to: rotated)
        XCTAssertThrowsError(try index.refresh())
        try Data(request([["role": "user", "content": "New generation"]]).utf8).write(to: url)
        let update = try XCTUnwrap(index.refresh())
        XCTAssertTrue(update.reset)
        XCTAssertNotEqual(update.snapshot.generation, first.generation)
        XCTAssertEqual(update.snapshot.requestCount, 1)
        XCTAssertThrowsError(try LogReader.detail(first.turns[0].events[0], snapshot: first))
        var archived = first
        archived.url = rotated
        XCTAssertTrue(try LogReader.detail(archived.turns[0].events[0], snapshot: archived).readable.contains("café"))
    }
    func testTruncateRewriteAndAppendAreDetected() throws {
        let url = try temp(request(messages))
        var index = LogIndex(url: url)
        let initial = try XCTUnwrap(index.refresh()?.snapshot)
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: 0)
        try file.close()
        XCTAssertTrue(try XCTUnwrap(index.refresh()).reset)
        try append(Data(request(messages).utf8), to: url)
        XCTAssertFalse(try XCTUnwrap(index.refresh()).reset)
        let replacement = try request([["role": "user", "content": String(repeating: "Different", count: 100)]])
        try Data(replacement.utf8).write(to: url, options: [])
        let result = try XCTUnwrap(index.refresh())
        XCTAssertTrue(result.reset)
        XCTAssertNotEqual(result.snapshot.generation, initial.generation)
        XCTAssertEqual(result.snapshot.requestCount, 1)
    }
    func testMissingSourceRecoversWithoutLosingState() throws {
        let url = try temp(request(messages))
        var index = LogIndex(url: url)
        _ = try index.refresh()
        let moved = url.appendingPathExtension("away")
        try FileManager.default.moveItem(at: url, to: moved)
        XCTAssertThrowsError(try index.refresh())
        try FileManager.default.moveItem(at: moved, to: url)
        XCTAssertNil(try index.refresh())
    }
    func testMetricsAndChangesUseObservedEvidence() throws {
        let more = messages + [["role": "assistant", "content": "Answer"], ["role": "user", "content": "Next"]]
        let text =
            try request(messages)
            + line("Added request a with 100 prompt tokens", logger: "omlx.scheduler", time: "15:12:08,000")
            + line("Request a finished: stop, 12 tokens", logger: "omlx.scheduler", time: "15:12:09,500")
            + request(more, tools: [["type": "function", "function": ["name": "demo"]]], temperature: 0.8)
            + line("Added request b with 120 prompt tokens", logger: "omlx.scheduler")
        let s = try LogReader.load(temp(text))
        let events = s.turns.flatMap(\.events).filter { $0.kind == .request }
        XCTAssertEqual(events[0].metrics?.elapsedSeconds, 1.5)
        XCTAssertEqual(events[0].metrics?.generatedTokens, 12)
        XCTAssertEqual(events[1].metrics?.changedFields, ["temperature", "tools"])
        XCTAssertTrue(try LogReader.detail(events[1], snapshot: s).readable.contains("Prompt-token change: +20"))
    }
    func testPossibleCompactionNeverMergesConversations() throws {
        let long =
            messages + [
                ["role": "assistant", "content": "A"], ["role": "tool", "content": "B"],
                ["role": "assistant", "content": "C"]
            ]
        let s = try LogReader.load(temp(request(long) + request(messages)))
        let events = s.turns.flatMap(\.events).filter { $0.kind == .request }
        XCTAssertNotEqual(s.turns[0].group, s.turns[1].group)
        XCTAssertTrue(events[1].metrics?.possibleReset == true)
        XCTAssertNil(events[1].continuation?.retainedMessages)
    }
    func testDuplicateResultsDoNotOverwriteOneToOneLink() throws {
        let later =
            messages + [
                ["role": "assistant", "tool_calls": [["id": "c", "function": ["name": "demo", "arguments": "{}"]]]],
                ["role": "tool", "tool_call_id": "c", "content": "first"],
                ["role": "tool", "tool_call_id": "c", "content": "second"]
            ]
        let s = try LogReader.load(temp(request(messages) + request(later)))
        let events = s.turns.flatMap(\.events)
        let results = events.filter { $0.kind == .result }
        XCTAssertEqual(events.first { $0.kind == .call }?.linkedEvent, results[0].id)
        XCTAssertNil(results[1].linkedEvent)
    }
    func testSearchFindsFullContentAndHonorsLimit() throws {
        let content = String(repeating: "padding ", count: 100) + "needle https://example.test/path"
        let s = try LogReader.load(
            temp(request([["role": "user", "content": content]]) + request([["role": "user", "content": content]])))
        let hits = try LogReader.search("EXAMPLE.TEST", snapshot: s)
        XCTAssertEqual(hits.hits.count, 4)
        XCTAssertTrue(hits.hits.allSatisfy { !$0.event.summary.contains("needle") })
        XCTAssertTrue(try LogReader.search("needle", snapshot: s, limit: 1).limited)
        XCTAssertTrue(try LogReader.search("absent", snapshot: s).hits.isEmpty)
        XCTAssertTrue(try LogReader.search("   ", snapshot: s).hits.isEmpty)
    }
    func testFiltersPreserveUnderlyingEvents() throws {
        let s = try LogReader.load(temp(request(messages) + line("bad", level: "WARNING")))
        let events = s.turns.flatMap(\.events)
        XCTAssertEqual(events.filter(EventFilter.requests.includes).count, 1)
        XCTAssertEqual(events.filter(EventFilter.issues.includes).count, 1)
        XCTAssertEqual(events.filter(EventFilter.messages.includes).count, 1)
        XCTAssertEqual(events.filter(EventFilter.all.includes).count, events.count)
    }
    func testSameLengthRewriteResetsGeneration() throws {
        let url = try temp(request(messages))
        var index = LogIndex(url: url)
        let first = try XCTUnwrap(index.refresh()?.snapshot)
        let bytes = try Data(contentsOf: url)
        let changed = String(decoding: bytes, as: UTF8.self).replacingOccurrences(
            of: "Instructions", with: "New guidance")
        XCTAssertEqual(changed.utf8.count, bytes.count)
        try Data(changed.utf8).write(to: url, options: [])
        let next = try XCTUnwrap(index.refresh())
        XCTAssertTrue(next.reset)
        XCTAssertNotEqual(next.snapshot.generation, first.generation)
    }
    func testCancelledIndexDoesNotPublishPartialWork() async throws {
        let url = try temp(request(messages))
        let task = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            var index = LogIndex(url: url)
            return try index.refresh()
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
    func testManyDistinctConversationsRemainIndependent() throws {
        var content = ""
        for i in 0..<3000 {
            content += try request([
                ["role": "system", "content": "Common instructions"],
                ["role": "user", "content": "Distinct question \(i)"]
            ])
        }
        let snapshot = try LogReader.load(temp(content))
        XCTAssertEqual(snapshot.turns.count, 3000)
        XCTAssertEqual(snapshot.requestCount, 3000)
        XCTAssertEqual(Set(snapshot.turns.map(\.group)).count, 3000)
    }
    func testMultiGigabyteIndexWhenRequested() throws {
        guard let value = ProcessInfo.processInfo.environment["INSPECTOR_LARGE_LOG_BYTES"], let size = Int(value) else {
            throw XCTSkip("Opt-in disk/performance test")
        }
        let url = try temp()
        let file = try FileHandle(forWritingTo: url)
        let noise = line(String(repeating: "x", count: 4000), logger: "omlx.cache", level: "DEBUG")
        let block = Data(String(repeating: noise, count: 256).utf8)
        var written = 0
        while written < size {
            try file.write(contentsOf: block)
            written += block.count
        }
        try file.write(contentsOf: Data(request(messages).utf8))
        try file.close()
        let start = Date()
        var index = LogIndex(url: url)
        let snapshot = try XCTUnwrap(index.refresh()?.snapshot)
        XCTAssertGreaterThanOrEqual(snapshot.size, UInt64(size))
        XCTAssertEqual(snapshot.requestCount, 1)
        XCTAssertEqual(snapshot.records.count, snapshot.recordCount)
        XCTAssertTrue(
            try LogReader.detail(XCTUnwrap(snapshot.records.first), snapshot: snapshot).raw.contains("omlx.cache"))
        XCTAssertTrue(try LogReader.detail(snapshot.turns[0].events[0], snapshot: snapshot).readable.contains("café"))
        XCTAssertNil(try index.refresh())
        let previousBytes = index.bytesRead
        let extra = Data(line("later", level: "WARNING").utf8)
        try append(extra, to: url)
        let appended = try XCTUnwrap(index.refresh()?.snapshot)
        XCTAssertEqual(index.bytesRead - previousBytes, UInt64(extra.count))
        XCTAssertEqual(appended.requestCount, 1)
        print(
            "LARGE LOG: bytes=\(snapshot.size) records=\(snapshot.recordCount) seconds=\(Date().timeIntervalSince(start)) appendBytes=\(extra.count)"
        )
    }
}
