// Compile with the InspectorCore sources. Uses only its own disposable synthetic log.
import Foundation
import Darwin
@main struct Benchmark {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("omlx-benchmark-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let file = try FileHandle(forWritingTo: url)
        let header = "2026-11-20 22:00:00,000 - omlx.server - TRACE - [-] - "
        let noise = Data((header + String(repeating: "x", count: 4000) + "\n").utf8)
        var block = Data(); for _ in 0..<256 { block.append(noise) }
        // Mix substantial irrelevant source volume with distinct indexed conversations.
        var count = 0
        while try file.offset() < 2 * 1024 * 1024 * 1024 {
            try autoreleasepool {
            try file.write(contentsOf: block)
            let request = header + "Incoming POST /v1/chat/completions — body: {\"model\":\"benchmark\",\"messages\":[{\"role\":\"user\",\"content\":\"Synthetic turn \(count)\"}],\"tools\":[]}\n"
            try file.write(contentsOf: Data(request.utf8)); count += 1
            }
        }
        try file.close()
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage); print("beforeIndexPeakBytes=\(usage.ru_maxrss)")
        let start = Date(); var index = LogIndex(url: url)
        let snapshot = try index.refresh()!.snapshot
        print("bytes=\(snapshot.size) records=\(snapshot.recordCount) turns=\(snapshot.turns.count) seconds=\(Date().timeIntervalSince(start))")
        precondition(snapshot.turns.count == count)
        let append = try FileHandle(forWritingTo: url); try append.seekToEnd()
        try append.write(contentsOf: Data((header + "idle marker\n").utf8)); try append.close()
        let previousBytes = index.bytesRead, appendStart = Date()
        _ = try index.refresh()
        print("incrementalBytes=\(index.bytesRead - previousBytes) incrementalSeconds=\(Date().timeIntervalSince(appendStart))")
    }
}
