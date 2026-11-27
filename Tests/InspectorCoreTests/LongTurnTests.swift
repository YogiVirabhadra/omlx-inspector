import XCTest
@testable import InspectorCore

final class LongTurnTests: XCTestCase {
    func testLongContinuationTurnRemainsCompleteAcrossLiveUpdatesAndPages() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("long-turn-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url)
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss,SSS"
        let base = try XCTUnwrap(format.date(from: "2026-11-21 10:00:00,000"))
        func line(_ body: String, _ seconds: Double, _ logger: String = "omlx.scheduler", _ level: String = "DEBUG") -> String {
            "\(format.string(from: base.addingTimeInterval(seconds))) - \(logger) - \(level) - [-] - \(body)\n"
        }
        var messages: [[String: Any]] = [["role": "user", "content": "One long verification turn"]]
        var index = LogIndex(url: url)
        var boundary: DisplayBoundary?
        var latest: LogSnapshot?
        for i in 0..<125 {
            if i > 0 {
                messages += [["role": "assistant", "tool_calls": [["id": "call-\(i)", "type": "function", "function": ["name": "terminal", "arguments": "{\"command\":\"date\"}"]]]],
                             ["role": "tool", "tool_call_id": "call-\(i)", "content": "Synthetic tool result \(i)"]]
            }
            let json = try JSONSerialization.data(withJSONObject: ["model": "long-turn", "messages": messages])
            let t = Double(i * 2), prompt = 100 + i * 10
            let block = line("Incoming POST /v1/chat/completions — body: " + String(decoding: json, as: UTF8.self), t, "omlx.server", "TRACE")
                + line("Added request r-\(i) with \(prompt) prompt tokens", t + 0.1)
                + line("Request r-\(i) finished: stop, 12 tokens", t + 1)
                + line("Request r-\(i) generated text:\nSynthetic output \(i)", t + 1, "omlx.scheduler", "TRACE")
                + line("Chat completion: model=long-turn, 12 tokens in 1.00s (12.0 tok/s), prompt: \(prompt), finish_reason=\(i == 124 ? "stop" : "tool_calls")", t + 1.01, "omlx.server", "INFO")
            let file = try FileHandle(forWritingTo: url); try file.seekToEnd()
            try file.write(contentsOf: Data(block.utf8)); try file.close()
            latest = try XCTUnwrap(index.refresh()).snapshot
            if i == 59 { boundary = DisplayBoundary(snapshot: latest!) }
        }
        let live = try XCTUnwrap(latest), full = try LogReader.load(url)
        XCTAssertEqual(live.turns.count, 1)
        let turn = try XCTUnwrap(live.turns.first)
        XCTAssertEqual(turn.requests, 125); XCTAssertEqual(turn.calls, 124)
        XCTAssertEqual(turn.events.count, 499)
        XCTAssertEqual(turn.events.map(\.id), full.turns[0].events.map(\.id))
        XCTAssertEqual(turn.events.filter { $0.kind == .request }.compactMap(\.completion), full.turns[0].events.filter { $0.kind == .request }.compactMap(\.completion))
        XCTAssertEqual(turn.timelineCycles(showContext: false).compactMap(\.number), Array(1...125))
        XCTAssertEqual(turn.metrics.peakPromptTokens, 1340)
        XCTAssertEqual(turn.metrics.elapsedSeconds ?? 0, 249.01, accuracy: 0.001)
        XCTAssertTrue(turn.metrics.hasTerminalCompletion)
        XCTAssertEqual(try XCTUnwrap(boundary).applying(to: live).requestCount, 65)
        let last = try XCTUnwrap(turn.events.last)
        XCTAssertTrue(try LogReader.detail(last, snapshot: live).raw.contains("Synthetic output 124"))
        XCTAssertEqual(try LogReader.search("Synthetic output 124", snapshot: live).hits.map(\.id), [last.id])
        XCTAssertEqual(turn.events.filter { $0.kind == .result && $0.linkedEvent != nil }.count, 124)
    }
}
