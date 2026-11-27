import Foundation

extension EvidenceBuilder {
    /// An INFO summary while a scheduler request is still active may have closed its
    /// HTTP lifetime without a normal scheduler finish. Do not retire it twice later.
    mutating func observePossibleActiveCompletion(_ completion: InferenceCompletion?) {
        for id in active {
            guard let location = scheduler[id] else { continue }
            let metrics = turns[location.turn].events[location.event].metrics
            if completion == nil || (completion?.model == metrics?.model && completion?.promptTokens == metrics?.promptTokens) {
                uncertainActiveCompletions.insert(id)
            }
        }
    }

    mutating func consumeCancellation(_ record: LogRecord) -> Bool {
        // This engine message comes from the generator's finally block when it did
        // not finish normally. A scheduler's "Enqueued deferred abort" alone does
        // not establish either an ended generator or completed cleanup.
        if record.logger == "omlx.engine.vlm", record.level == "INFO",
           let id = LogReader.captures(#"^\[vlm_stream_generate\] Aborting request ([A-Za-z0-9_-]+)$"#, record.body)?.first {
            if cancellationStarts[id] == nil { cancellationStarts[id] = record.source }
            return true
        }
        if record.logger == "omlx.scheduler", record.level == "DEBUG",
           let id = LogReader.captures(#"^Aborted request ([A-Za-z0-9_-]+)$"#, record.body)?.first {
            retireCancelledRequest(id, record: record)
            return true
        }
        if record.logger == "omlx.engine_core", record.level == "DEBUG",
           let parts = LogReader.captures(#"^Reaped (\d+) orphaned output collector\(s\) after disconnect: (\[[^\r\n]*\])$"#, record.body),
           let ids = try? JSONSerialization.jsonObject(with: Data(parts[1].replacingOccurrences(of: "'", with: "\"").utf8)) as? [String],
           ids.count == Int(parts[0]), Set(ids).count == ids.count,
           ids.allSatisfy({ LogReader.captures(#"^([A-Za-z0-9_-]+)$"#, $0) != nil }) {
            for id in ids { retireCancelledRequest(id, record: record) }
            return true
        }
        return false
    }

    private mutating func retireCancelledRequest(_ id: String, record: LogRecord) {
        // Idempotent: duplicate cleanup must never consume another request's lifetime.
        guard active.remove(id) != nil else { return }
        let start = cancellationStarts.removeValue(forKey: id)
        let uncertain = uncertainActiveCompletions.remove(id) != nil
        guard let start else { return } // Finished collector alone does not prove cancellation.
        let location = scheduler[id]
        let retired = location != nil && !uncertain && completionOpen > 0
        if retired {
            completionOpen -= 1
            // Never repair a window that actually overlapped the canceled request.
            // Only a later isolated request can establish a fresh completion window.
            completionWindow = nil
            if completionOpen == 0 { completionOverlap = false }
        }
        let explanation = retired
            ? "Engine cancellation and completed cleanup share scheduler UUID \(id). Its incoming request association is inferred from the earlier unambiguous scheduler admission. The canceled lifetime was retired; no server finish reason or successful completion is inferred."
            : "Cancellation cleanup for scheduler UUID \(id) was observed, but its unresolved incoming lifetime could not be uniquely established. Completion associations remain conservative."
        if let location {
            turns[location.turn].events[location.event].note += " " + explanation
        }
        diagnostic(record, title: "Canceled request cleanup",
                   note: explanation + " Engine abort evidence begins at line \(start.line). Source shows the original cleanup record.")
        if !retired { warn(explanation) }
    }
}
