// Compile with InspectorCore sources; reads the supplied log without printing its content.
import Foundation
import Darwin

@main struct LogMetrics {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw InspectorError.invalid("Pass one log path")
        }
        let start = Date()
        let snapshot = try LogReader.load(URL(fileURLWithPath: CommandLine.arguments[1]))
        let events = snapshot.turns.flatMap(\.events)
        let requests = events.filter { $0.kind == .request }
        let outputs = events.filter { $0.kind == .output }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        print("requests=\(requests.count) admitted=\(requests.filter { $0.requestID != nil }.count) outputs=\(outputs.count) unlinkedOutputs=\(snapshot.turns.filter { $0.title == "Unlinked model output" }.count) completions=\(requests.filter { $0.completion != nil }.count) conversations=\(Set(snapshot.turns.filter { $0.group != 0 }.map(\.group)).count) seconds=\(Date().timeIntervalSince(start)) peakBytes=\(usage.ru_maxrss)")
    }
}
