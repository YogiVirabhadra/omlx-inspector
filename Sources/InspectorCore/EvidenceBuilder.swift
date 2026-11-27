import Foundation
import CryptoKit

struct EvidenceBuilder: Sendable {
    // Keep compact immutable request checkpoints for branches. Only current heads
    // retain message hashes for possible-reset comparisons, avoiding a full copy
    // of every growing message history across a long turn.
    struct History: Sendable { var headHashes: [String]?; var count: Int; var group: Int; var turn: Int; var requestID: String; var fields: [String: String]; var lastUser: String?; var chain: String; var userPositions: Set<Int>; var children: [Int] = [] }
    var turns: [InspectorTurn] = []
    var histories: [History] = []
    var historyChains: [String: [Int]] = [:]
    var historiesByUser: [String: [Int]] = [:]
    var nextGroup = 1
    var warnings: [String] = []
    var pending: [(turn: Int, event: Int)] = []
    var active: Set<String> = []
    var scheduler: [String: (turn: Int, event: Int)] = [:]
    var calls: [String: [(turn: Int, event: Int)]] = [:]
    var diagnostics: Int? = nil
    var cancellationStarts: [String: SourceRef] = [:]
    var uncertainActiveCompletions: Set<String> = []
    var completionOpen = 0
    var completionOverlap = false
    var completionWindow: CompletionWindow?

    mutating func warn(_ message: String) { if !warnings.contains(message) { warnings.append(message) } }

    mutating func diagnostic(_ r: LogRecord, title: String, note: String = "Observed log record; not automatically attributed to a user turn.") {
        if diagnostics == nil {
            diagnostics = turns.count
            turns.append(InspectorTurn(id: "diagnostics", title: "Log diagnostics", group: 0, observed: r.timestamp, events: []))
        }
        turns[diagnostics!].events.append(InspectorEvent(id: "d\(r.source.offset)", kind: .diagnostic, title: title, summary: LogReader.preview(r.body), timestamp: r.timestamp, note: note, evidence: Evidence(source: r.source)))
    }
    mutating func consume(_ r: LogRecord) throws {
        try Task.checkCancellation()
        if r.body.hasPrefix("Incomplete final record") || r.logger == "unknown" {
            diagnostic(r, title: "Incomplete or unframed record"); warn("Some source content could not be framed as complete records."); return
        }
        if consumeCancellation(r) { return }
        if r.logger == "omlx.server", r.body.hasPrefix("Incoming POST /v1/chat/completions — body:") {
            completionOpen += 1
            if completionOpen > 1 { completionOverlap = true }
            completionWindow = nil
            do { try request(r) } catch {
                diagnostic(r, title: "Request could not be decoded")
                warn("At least one request body could not be decoded.")
                // An unparsed incoming request prevents safe temporal linking.
                pending.removeAll()
            }
            return
        }
        if r.logger == "omlx.server", r.level == "INFO", r.body.hasPrefix("Chat completion:") {
            consumeCompletion(r); return
        }
        if r.logger == "omlx.scheduler", let m = LogReader.captures(#"^Added request (\S+) with (\d+) prompt tokens"#, r.body) {
            // Already-attributed active UUIDs are not candidates for this new
            // scheduler admission. Keep matching one unmatched incoming request
            // even while those older requests run. An unattributed active UUID
            // or multiple pending arrivals still prevents a safe association.
            if pending.count == 1 && active.allSatisfy({ scheduler[$0] != nil }) {
                let p = pending[0]; scheduler[m[0]] = p
                if completionWindow?.turn == p.turn && completionWindow?.event == p.event {
                    completionWindow?.schedulerID = m[0]
                } else { completionWindow = nil }
                turns[p.turn].events[p.event].requestID = m[0]
                turns[p.turn].events[p.event].metrics?.promptTokens = Int(m[1])
                turns[p.turn].events[p.event].metrics?.schedulerStart = r.timestamp
                turns[p.turn].events[p.event].note += " Scheduler association inferred: one unmatched incoming request at admission, with all earlier active scheduler UUIDs already attributed; \(m[1]) prompt tokens reported by scheduler."
            } else {
                completionWindow = nil
                if !pending.isEmpty { warn("Overlapping or ambiguous requests were not paired to scheduler output.") }
            }
            pending.removeAll(); active.insert(m[0]); return
        }
        if r.logger == "omlx.scheduler", let m = LogReader.captures(#"^Request (\S+) finished:"#, r.body) {
            if let p = scheduler[m[0]] {
                if let tokens = LogReader.captures(#"finished: .*, (\d+) tokens"#, r.body)?.first {
                    turns[p.turn].events[p.event].metrics?.generatedTokens = Int(tokens)
                }
                if let start = turns[p.turn].events[p.event].metrics?.schedulerStart,
                   let seconds = Self.elapsed(start, r.timestamp), seconds >= 0 {
                    turns[p.turn].events[p.event].metrics?.elapsedSeconds = seconds
                }
            }
            if completionWindow?.schedulerID == m[0], active.count == 1 {
                completionWindow?.finishedAt = r.timestamp
            } else { completionWindow = nil }
            active.remove(m[0]); return
        }
        if r.logger == "omlx.scheduler", let m = LogReader.captures(#"^Request (\S+) generated text:"#, r.body) {
            let parts = r.body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let body = parts.count > 1 ? String(parts[1]) : ""
            let t: Int
            let note: String
            if let p = scheduler[m[0]] {
                t = p.turn; note = "Output and scheduler share an explicit request ID. Association with the incoming request is inferred."
            } else {
                t = turns.count
                turns.append(InspectorTurn(id: "unlinked\(r.source.offset)", title: "Unlinked model output", group: nextGroup, observed: r.timestamp, events: [])); nextGroup += 1
                note = "Observed scheduler output. No unambiguous incoming request association is available."
            }
            turns[t].events.append(InspectorEvent(id: "o\(r.source.offset)", kind: .output, title: "Generated output", summary: LogReader.preview(LogReader.withoutReasoning(body)), timestamp: r.timestamp, note: note, evidence: Evidence(source: r.source, generated: true), requestID: m[0]))
            if completionWindow?.schedulerID == m[0], completionWindow?.finishedAt != nil, active.isEmpty {
                completionWindow?.outputAt = r.timestamp
                completionWindow?.outputEvent = turns[t].events.count - 1
            } else { completionWindow = nil }
            // Raw syntax indicates intent only. Structured calls from subsequent history are authoritative for IDs.
            if body.contains("<|tool_call>") || body.contains("<tool_call>") {
                turns[t].events[turns[t].events.count - 1].title = "Generated tool-call intent"
                turns[t].events[turns[t].events.count - 1].note += " Raw model syntax; structured calls, if later reported, appear separately. Multiline boundaries follow log-header syntax and cannot disambiguate generated text that perfectly imitates a log header."
            }
            return
        }
        if r.level == "ERROR" || r.level == "WARNING" || r.level == "CRITICAL" {
            diagnostic(r, title: r.level.capitalized)
        }
    }
    mutating func request(_ r: LogRecord) throws {
        let x = try LogReader.json(r)
        guard let messages = x["messages"] as? [[String: Any]], !messages.isEmpty else { throw InspectorError.invalid("Missing messages") }
        let hashes = messages.map(LogReader.fingerprint)
        let fields = x.filter { $0.key != "messages" }.mapValues(LogReader.fingerprint)
            .merging(["system instructions": LogReader.fingerprint(messages.filter { ["system", "developer"].contains($0["role"] as? String ?? "") })]) { _, new in new }
        let lastUser = messages.last(where: { $0["role"] as? String == "user" }).map(LogReader.fingerprint)

        // Lookup complete predecessor chains in O(message count), rather than
        // scanning every historical conversation for every incoming request.
        var chain = ""
        let chains = hashes.map { hash in
            chain = SHA256.hash(data: Data((chain + hash).utf8)).description
            return chain
        }
        // A repeated rich history can be a retry/replay. Opening-only prompts may be
        // unrelated sessions and must not merge simply because their text matches.
        let richHistory = messages.contains { ["assistant", "tool"].contains($0["role"] as? String ?? "") }
        let exact = richHistory ? historyChains[chain] ?? [] : []
        let candidates = exact.isEmpty ? chains.dropLast().flatMap { historyChains[$0] ?? [] } : exact
        let bestLength = candidates.map { histories[$0].count }.max() ?? 0
        let best = candidates.filter { histories[$0].count == bestLength }
        let seenUsers = messages.indices.filter { messages[$0]["role"] as? String == "user" }
        // Replays create several checkpoints of one history, not competing origins.
        // Resolve only within one already-inferred group/turn and matching model.
        let origin = best.first.map { histories[$0] }
        let uniqueOrigin = origin.map { h in best.allSatisfy {
            histories[$0].group == h.group && histories[$0].turn == h.turn && histories[$0].fields["model"] == fields["model"]
        } } ?? false
        let matched = uniqueOrigin ? best.reversed().first(where: { i in
            !exact.isEmpty || histories[i].headHashes != nil || isUserBranch(from: i, hashes: hashes, users: Set(seenUsers))
        }) : nil
        let group: Int; var turn: Int; let skip: Int
        if let i = matched {
            group = histories[i].group; turn = histories[i].turn; skip = histories[i].count
        } else {
            group = nextGroup; nextGroup += 1; skip = 0; turn = -1
        }
        for i in skip..<messages.count {
            let m = messages[i]; let role = m["role"] as? String ?? "unknown"
            let content = LogReader.string(m["content"])
            let notification = role == "user" ? Self.backgroundNotification(content) : nil
            if role == "system" { continue }
            if role == "user" || turn < 0 {
                let title = notification.map { "Background process notification · \($0)" }
                    ?? (role == "user" ? LogReader.preview(content, limit: 140) : "Carried conversation context")
                turn = turns.count
                turns.append(InspectorTurn(id: "t\(r.source.offset)-\(i)", title: title.isEmpty ? "User message without text" : title, group: group, observed: r.timestamp, events: []))
            }
            let historical = skip == 0 && (seenUsers.last.map { i < $0 } ?? false)
            let note = historical ? "Historical context first seen in this request. Original event time is unavailable." : "First observed in this request's message history; original message time is unavailable. Conversation continuity is inferred from exact history prefixes."
            let ref = Evidence(source: r.source, message: i)
            let eid = "m\(r.source.offset)-\(i)"
            if role == "user" {
                turns[turn].events.append(InspectorEvent(id: eid, kind: .user, title: notification != nil ? "Background process notification" : (historical ? "Earlier user message" : "User message"), summary: LogReader.preview(content), timestamp: r.timestamp, note: note + (notification != nil ? " The message identifies itself as a Hermes gateway notification, not a human-authored user message." : ""), evidence: ref))
            } else if role == "tool" {
                let toolID = m["tool_call_id"] as? String
                let eligible = toolID.flatMap { calls["\(group):\($0)"] } ?? []
                let linked = eligible.count == 1 && turns[eligible[0].turn].events[eligible[0].event].linkedEvent == nil ? eligible[0] : nil
                let name = linked.map { turns[$0.turn].events[$0.event].title } ?? "Unmatched tool"
                var event = InspectorEvent(id: eid, kind: .result, title: "\(name) result", summary: LogReader.resultSummary(content), timestamp: r.timestamp, note: note + " This is an agent-reported result, not independent execution telemetry.", evidence: ref, toolID: toolID)
                if let p = linked {
                    event.linkedEvent = turns[p.turn].events[p.event].id
                    turns[p.turn].events[p.event].linkedEvent = eid
                    turns[p.turn].events[p.event].note += " Result matched by explicit tool-call ID within the inferred conversation."
                }
                turns[turn].events.append(event)
            } else if role == "assistant" {
                if let toolCalls = m["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                    for (j,c) in toolCalls.enumerated() {
                        let fn = c["function"] as? [String: Any] ?? [:]
                        let id = c["id"] as? String
                        let event = InspectorEvent(id: "\(eid)c\(j)", kind: .call, title: fn["name"] as? String ?? "Unnamed tool", summary: LogReader.preview(LogReader.string(fn["arguments"])), timestamp: r.timestamp, note: note + " Structured call reported by the agent.", evidence: Evidence(source: r.source, message: i, call: j), toolID: id)
                        if let id { calls["\(group):\(id)", default: []].append((turn, turns[turn].events.count)) }
                        turns[turn].events.append(event)
                    }
                }
                if !content.isEmpty {
                    turns[turn].events.append(InspectorEvent(id: eid, kind: .context, title: "Assistant message in history", summary: LogReader.preview(content), timestamp: r.timestamp, note: note + " May repeat a previously observed generated output.", evidence: ref))
                }
            } else {
                turns[turn].events.append(InspectorEvent(id: eid, kind: .context, title: "\(role.capitalized) message", summary: LogReader.preview(content), timestamp: r.timestamp, note: note, evidence: ref))
            }
        }
        if turn < 0 {
            turn = turns.count; turns.append(InspectorTurn(id: "t\(r.source.offset)", title: "Request without a user turn", group: group, observed: r.timestamp, events: []))
        }
        if let format = x["response_format"] as? [String: Any], let schema = format["json_schema"] as? [String: Any], schema["name"] as? String == "session_title" {
            turns[turn].title = "Session title generation (inferred)"
        }
        let model = x["model"] as? String ?? "Unspecified model"
        let n = turns[turn].requests + 1
        let toolCount = (x["tools"] as? [Any])?.count ?? 0
        let addedMessages = Array(messages.dropFirst(skip))
        let resultMessages = addedMessages.filter { $0["role"] as? String == "tool" }
        let reason: String
        if let user = addedMessages.last(where: { $0["role"] as? String == "user" }), Self.backgroundNotification(LogReader.string(user["content"])) != nil {
            reason = "Responding to a background-process notification"
        } else if matched != nil && skip == messages.count {
            reason = "Repeated request history (retry or replay)"
        } else if matched == nil {
            reason = "Starting this turn"
        } else if addedMessages.contains(where: { $0["role"] as? String == "user" }) {
            reason = "Responding to a new user message"
        } else if !resultMessages.isEmpty {
            let names = resultMessages.map { result -> String? in
                guard let id = result["tool_call_id"] as? String else { return nil }
                let matching = messages.flatMap { $0["tool_calls"] as? [[String: Any]] ?? [] }.filter { $0["id"] as? String == id }
                guard matching.count == 1 else { return nil }
                return (matching[0]["function"] as? [String: Any])?["name"] as? String
            }
            if resultMessages.count == 1 {
                reason = "Continuing after \(names[0] ?? "a tool") result"
            } else if let first = names[0], names.allSatisfy({ $0 == first }) {
                reason = "Continuing after \(resultMessages.count) \(first) results"
            } else {
                reason = "Continuing after \(resultMessages.count) tool results"
            }
        } else {
            reason = "Continuing with new conversation context"
        }
        var metrics = RequestMetrics(model: model)
        let possible = matched == nil ? (lastUser.flatMap { historiesByUser[$0] } ?? []).filter {
            let h = histories[$0]
            guard let headHashes = h.headHashes else { return false }
            return lastUser != nil && h.lastUser == lastUser && h.chain != chain &&
                Set(headHashes).intersection(hashes).count >= 2
        } : []
        if let prior = matched ?? (possible.count == 1 ? possible.first : nil) {
            let h = histories[prior]
            metrics.previousRequest = h.requestID
            metrics.comparisonInferred = true
            metrics.possibleReset = matched == nil
            metrics.changedFields = Set(fields.keys).union(h.fields.keys).filter { fields[$0] != h.fields[$0] }.sorted()
        }
        let explanation: String
        if matched != nil {
            explanation = skip == messages.count
                ? "Identical complete history in one inferred conversation; shown as another inference. A retry cannot be distinguished from a replay."
                : "Continuation inferred from an exact earlier message-history prefix, independent of intervening requests from other streams."
        } else if !best.isEmpty {
            explanation = uniqueOrigin
                ? "History diverged from an older checkpoint outside a verified user-message branch. Kept separate to avoid joining rewritten histories."
                : "Several earlier histories or different models could explain this request. No unique predecessor; kept separate."
        } else if metrics.possibleReset {
            explanation = "History changed, was shortened, or had instructions rewritten. A comparison candidate is available; conversation continuity is unverified."
        } else {
            explanation = "No exact earlier message-history prefix was found. This may be a new conversation, changed history, or a conversation that began in another log."
        }
        let continuation = RequestContinuation(reason: reason, totalMessages: messages.count, retainedMessages: matched == nil ? nil : skip, explanation: explanation)
        let event = InspectorEvent(id: "r\(r.source.offset)", kind: .request, title: "Request \(n)", summary: "\(model) · \(messages.count) messages · \(toolCount) tool definitions", timestamp: r.timestamp, note: "Observed incoming request. \(skip) unchanged messages suppressed in the timeline. \(explanation) Complete history, system instructions, reasoning fields, tools, and parameters remain in Structured / Source.", evidence: Evidence(source: r.source), continuation: continuation, metrics: metrics)
        if completionOpen == 1 && !completionOverlap {
            completionWindow = CompletionWindow(turn: turn, event: turns[turn].events.count)
        }
        pending.append((turn, turns[turn].events.count)); turns[turn].events.append(event)
        let index = histories.count
        if let i = matched {
            let previous = histories[i]
            histories[i].headHashes = nil
            histories[i].children.append(index)
            if let user = previous.lastUser {
                historiesByUser[user]?.removeAll { $0 == i }
                if historiesByUser[user]?.isEmpty == true { historiesByUser.removeValue(forKey: user) }
            }
        }
        let history = History(headHashes: hashes, count: hashes.count, group: group, turn: turn, requestID: event.id, fields: fields, lastUser: lastUser, chain: chain, userPositions: Set(seenUsers))
        histories.append(history)
        historyChains[chain, default: []].append(index)
        if let lastUser { historiesByUser[lastUser, default: []].append(index) }
    }
    private func isUserBranch(from ancestor: Int, hashes: [String], users: Set<Int>) -> Bool {
        // An old opening alone is insufficient: compressed/edited history can
        // share it too. Require exact shared messages up to a new user-message
        // fork on every descendant head. Rewritten tool results or assistant
        // history remain uncertain rather than being attached to the old turn.
        var remaining = histories[ancestor].children
        var foundHead = false
        while let index = remaining.popLast() {
            let history = histories[index]
            guard let head = history.headHashes else {
                remaining.append(contentsOf: history.children)
                continue
            }
            let common = zip(hashes, head).prefix { $0 == $1 }.count
            guard common < hashes.count, common < head.count,
                  users.contains(common), history.userPositions.contains(common) else { return false }
            foundHead = true
        }
        return foundHead
    }
    private static func backgroundNotification(_ content: String) -> String? {
        guard content.contains("[INTERNAL NOTIFICATION — generated by the Hermes gateway, not written by a human user.") else { return nil }
        return LogReader.captures(#"^\[IMPORTANT: Background process ([A-Za-z0-9_-]+) completed"#, content)?.first
    }
    static func elapsed(_ start: String, _ end: String) -> Double? {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss,SSS"
        guard let a = format.date(from: start), let b = format.date(from: end) else { return nil }
        return b.timeIntervalSince(a)
    }
    mutating func finish() {
        warnings = Array(Set(warnings)).sorted()
        for t in turns.indices {
            for e in turns[t].events.indices where turns[t].events[e].kind == .call && turns[t].events[e].linkedEvent == nil {
                turns[t].events[e].note += " Result not observed or not uniquely matchable."
            }
        }
    }
}
