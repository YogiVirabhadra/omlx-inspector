import Foundation

/// Turns framed log records into conversations, turns, and timeline events.
///
/// Records are consumed strictly in source order. Every association between records
/// (history continuity, scheduler admission, completion) is made only when the evidence is
/// unambiguous; otherwise the records stay separate and the uncertainty is explained in the
/// event notes.
struct EvidenceBuilder: Sendable {
    // Keep compact immutable request checkpoints for branches. Only current heads
    // retain message hashes for possible-reset comparisons, avoiding a full copy
    // of every growing message history across a long turn.
    struct History: Sendable {
        var headHashes: [String]?
        var count: Int
        var group: Int
        var turn: Int
        var requestID: String
        var fields: [String: String]
        var lastUser: String?
        var chain: String
        var userPositions: Set<Int>
        var children: [Int] = []
    }
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

    /// Appends an unattributed event to the shared "Log diagnostics" turn.
    ///
    /// Pass a `discriminator` when one source record can produce several diagnostics,
    /// so that every event keeps a unique identifier.
    mutating func diagnostic(
        _ record: LogRecord, title: String,
        note: String = "Observed log record; not automatically attributed to a user turn.",
        discriminator: String? = nil
    ) {
        if diagnostics == nil {
            diagnostics = turns.count
            turns.append(
                InspectorTurn(
                    id: Identifiers.diagnosticsTurn, title: "Log diagnostics", group: 0, observed: record.timestamp,
                    events: []))
        }
        turns[diagnostics!].events.append(
            InspectorEvent(
                id: Identifiers.diagnosticEvent(at: record.source.offset, discriminator: discriminator),
                kind: .diagnostic,
                title: title,
                summary: TextPreview.singleLine(record.body), timestamp: record.timestamp, note: note,
                evidence: Evidence(source: record.source)))
    }
    /// Interprets one complete record. The order of the checks below is significant.
    mutating func consume(_ record: LogRecord) throws {
        try Task.checkCancellation()
        if record.body.hasPrefix(LogGrammar.incompleteRecordPrefix) || record.logger == LogGrammar.unknownLogger {
            diagnostic(record, title: "Incomplete or unframed record")
            warn("Some source content could not be framed as complete records.")
            return
        }
        if consumeCancellation(record) { return }
        if LogGrammar.incomingRequest.matches(record) {
            completionOpen += 1
            if completionOpen > 1 { completionOverlap = true }
            completionWindow = nil
            do { try request(record) } catch {
                diagnostic(record, title: "Request could not be decoded")
                warn("At least one request body could not be decoded.")
                // An unparsed incoming request prevents safe temporal linking.
                pending.removeAll()
            }
            return
        }
        if LogGrammar.completionSummary.matches(record) {
            consumeCompletion(record)
            return
        }
        if let captures = LogGrammar.schedulerAdded.captures(in: record) {
            // Already-attributed active UUIDs are not candidates for this new
            // scheduler admission. Keep matching one unmatched incoming request
            // even while those older requests run. An unattributed active UUID
            // or multiple pending arrivals still prevents a safe association.
            if pending.count == 1 && active.allSatisfy({ scheduler[$0] != nil }) {
                let arrival = pending[0]
                scheduler[captures[0]] = arrival
                if completionWindow?.turn == arrival.turn && completionWindow?.event == arrival.event {
                    completionWindow?.schedulerID = captures[0]
                } else {
                    completionWindow = nil
                }
                turns[arrival.turn].events[arrival.event].requestID = captures[0]
                turns[arrival.turn].events[arrival.event].metrics?.promptTokens = Int(captures[1])
                turns[arrival.turn].events[arrival.event].metrics?.schedulerStart = record.timestamp
                turns[arrival.turn].events[arrival.event].note +=
                    " Scheduler association inferred: one unmatched incoming request at admission, with all earlier active scheduler UUIDs already attributed; \(captures[1]) prompt tokens reported by scheduler."
            } else {
                completionWindow = nil
                if !pending.isEmpty { warn("Overlapping or ambiguous requests were not paired to scheduler output.") }
            }
            pending.removeAll()
            active.insert(captures[0])
            return
        }
        if let captures = LogGrammar.schedulerFinished.captures(in: record) {
            if let arrival = scheduler[captures[0]] {
                if let tokens = LogGrammar.finishedTokens.captures(in: record.body)?.first {
                    turns[arrival.turn].events[arrival.event].metrics?.generatedTokens = Int(tokens)
                }
                if let start = turns[arrival.turn].events[arrival.event].metrics?.schedulerStart,
                    let seconds = Self.elapsedSeconds(from: start, to: record.timestamp), seconds >= 0
                {
                    turns[arrival.turn].events[arrival.event].metrics?.elapsedSeconds = seconds
                }
            }
            if completionWindow?.schedulerID == captures[0], active.count == 1 {
                completionWindow?.finishedAt = record.timestamp
            } else {
                completionWindow = nil
            }
            active.remove(captures[0])
            return
        }
        if let captures = LogGrammar.generatedOutput.captures(in: record) {
            let parts = record.body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let body = parts.count > 1 ? String(parts[1]) : ""
            let turn: Int
            let note: String
            if let arrival = scheduler[captures[0]] {
                turn = arrival.turn
                note =
                    "Output and scheduler share an explicit request ID. Association with the incoming request is inferred."
            } else {
                turn = turns.count
                turns.append(
                    InspectorTurn(
                        id: Identifiers.unlinkedOutputTurn(outputAt: record.source.offset),
                        title: "Unlinked model output", group: nextGroup,
                        observed: record.timestamp, events: []))
                nextGroup += 1
                note = "Observed scheduler output. No unambiguous incoming request association is available."
            }
            turns[turn].events.append(
                InspectorEvent(
                    id: Identifiers.outputEvent(at: record.source.offset), kind: .output, title: "Generated output",
                    summary: TextPreview.singleLine(TextPreview.withoutReasoning(body)), timestamp: record.timestamp,
                    note: note, evidence: Evidence(source: record.source, generated: true), requestID: captures[0]))
            if completionWindow?.schedulerID == captures[0], completionWindow?.finishedAt != nil, active.isEmpty {
                completionWindow?.outputAt = record.timestamp
                completionWindow?.outputEvent = turns[turn].events.count - 1
            } else {
                completionWindow = nil
            }
            // Raw syntax indicates intent only. Structured calls from subsequent history are authoritative for IDs.
            if LogGrammar.toolIntentMarkers.contains(where: body.contains) {
                turns[turn].events[turns[turn].events.count - 1].title = "Generated tool-call intent"
                turns[turn].events[turns[turn].events.count - 1].note +=
                    " Raw model syntax; structured calls, if later reported, appear separately. Multiline boundaries follow log-header syntax and cannot disambiguate generated text that perfectly imitates a log header."
            }
            return
        }
        if LogGrammar.problemLevels.contains(record.level) {
            diagnostic(record, title: record.level.capitalized)
        }
    }

    /// Reconstructs one incoming chat-completion request: history continuity,
    /// timeline events, continuation reason, metrics, and the new checkpoint.
    mutating func request(_ record: LogRecord) throws {
        let request = try RequestPayload(decoding: record)
        let payload = request.raw
        guard let messages = request.messages, !messages.isEmpty else {
            throw InspectorError.missingMessages
        }
        // Fingerprints always use the original JSON values; the typed view is only for reading fields.
        let typed = messages.map(RequestPayload.Message.init(raw:))
        let hashes = messages.map(JSONText.fingerprint)
        let fields = payload.filter { $0.key != "messages" }.mapValues(JSONText.fingerprint)
            .merging([
                "system instructions": JSONText.fingerprint(
                    typed.filter { ["system", "developer"].contains($0.role) }.map(\.raw))
            ]) { _, new in new }
        let lastUser = typed.last(where: { $0.role == "user" }).map { JSONText.fingerprint($0.raw) }

        // Lookup complete predecessor chains in O(message count), rather than
        // scanning every historical conversation for every incoming request.
        let chains = rollingChainHashes(of: hashes)
        let chain = chains.last ?? ""
        let userPositions = typed.indices.filter { typed[$0].role == "user" }
        let prior = matchHistory(
            hashes: hashes, chains: chains, messages: typed, fields: fields, userPositions: userPositions)

        let group: Int
        var turn: Int
        let skip: Int
        if let matched = prior.matched {
            group = histories[matched].group
            turn = histories[matched].turn
            skip = histories[matched].count
        } else {
            group = nextGroup
            nextGroup += 1
            skip = 0
            turn = -1
        }
        turn = appendMessageEvents(
            typed, from: skip, startingAt: turn, group: group, seenUsers: userPositions, record: record)
        if turn < 0 {
            turn = turns.count
            turns.append(
                InspectorTurn(
                    id: Identifiers.turnWithoutUser(requestAt: record.source.offset),
                    title: "Request without a user turn", group: group,
                    observed: record.timestamp, events: []))
        }
        if request.isSessionTitle {
            turns[turn].title = "Session title generation (inferred)"
        }

        let model = request.model
        let requestNumber = turns[turn].requestCount + 1
        let toolCount = request.toolCount
        let addedMessages = Array(typed.dropFirst(skip))
        let reason = continuationReason(for: addedMessages, matched: prior.matched, allMessages: typed)
        let metrics = requestMetrics(
            model: model, matched: prior.matched, lastUser: lastUser, fields: fields, hashes: hashes, chain: chain)
        let explanation = continuityExplanation(
            matched: prior.matched, skip: skip, messageCount: messages.count, uniqueOrigin: prior.uniqueOrigin,
            hasCandidates: prior.hasCandidates, metrics: metrics)
        let continuation = RequestContinuation(
            reason: reason, totalMessages: messages.count, retainedMessages: prior.matched == nil ? nil : skip,
            explanation: explanation)
        let event = InspectorEvent(
            id: Identifiers.requestEvent(at: record.source.offset), kind: .request, title: "Request \(requestNumber)",
            summary: "\(model) · \(messages.count) messages · \(toolCount) tool definitions",
            timestamp: record.timestamp,
            note:
                "Observed incoming request. \(skip) unchanged messages suppressed in the timeline. \(explanation) Complete history, system instructions, reasoning fields, tools, and parameters remain in Structured / Source.",
            evidence: Evidence(source: record.source), continuation: continuation, metrics: metrics)
        if completionOpen == 1 && !completionOverlap {
            completionWindow = CompletionWindow(turn: turn, event: turns[turn].events.count)
        }
        pending.append((turn, turns[turn].events.count))
        turns[turn].events.append(event)
        checkpointHistory(
            matched: prior.matched, hashes: hashes, group: group, turn: turn, requestID: event.id, fields: fields,
            lastUser: lastUser, chain: chain, userPositions: userPositions)
    }

    /// Rolling SHA-256 chain hashes, one per message, so a complete predecessor
    /// chain can be looked up without rescanning every stored conversation.
    private func rollingChainHashes(of hashes: [String]) -> [String] {
        var chain = ""
        return hashes.map { hash in
            chain = SHA256Hex.digest(of: Data((chain + hash).utf8))
            return chain
        }
    }

    /// The outcome of searching stored checkpoints for a unique predecessor.
    private struct HistoryMatch {
        var matched: Int?
        var uniqueOrigin: Bool
        var hasCandidates: Bool
    }

    /// Searches stored checkpoints for the unique earlier message-history prefix
    /// that explains this request. Ambiguity is preserved, not guessed away.
    private func matchHistory(
        hashes: [String], chains: [String], messages: [RequestPayload.Message], fields: [String: String],
        userPositions: [Int]
    ) -> HistoryMatch {
        let chain = chains.last ?? ""
        // A repeated rich history can be a retry/replay. Opening-only prompts may be
        // unrelated sessions and must not merge simply because their text matches.
        let richHistory = messages.contains { ["assistant", "tool"].contains($0.role) }
        let exact = richHistory ? historyChains[chain] ?? [] : []
        let candidates = exact.isEmpty ? chains.dropLast().flatMap { historyChains[$0] ?? [] } : exact
        let bestLength = candidates.map { histories[$0].count }.max() ?? 0
        let best = candidates.filter { histories[$0].count == bestLength }
        // Replays create several checkpoints of one history, not competing origins.
        // Resolve only within one already-inferred group/turn and matching model.
        let origin = best.first.map { histories[$0] }
        let uniqueOrigin =
            origin.map { originHistory in
                best.allSatisfy {
                    histories[$0].group == originHistory.group && histories[$0].turn == originHistory.turn
                        && histories[$0].fields["model"] == fields["model"]
                }
            } ?? false
        let matched =
            uniqueOrigin
            ? best.reversed().first(where: { index in
                !exact.isEmpty || histories[index].headHashes != nil
                    || isUserBranch(from: index, hashes: hashes, users: Set(userPositions))
            }) : nil
        return HistoryMatch(matched: matched, uniqueOrigin: uniqueOrigin, hasCandidates: !best.isEmpty)
    }

    /// Emits timeline events for every message not already observed in this
    /// conversation. Returns the turn that received the last message (-1 if none).
    private mutating func appendMessageEvents(
        _ messages: [RequestPayload.Message], from skip: Int, startingAt initialTurn: Int, group: Int,
        seenUsers: [Int],
        record: LogRecord
    ) -> Int {
        var turn = initialTurn
        let lastSeenUser = seenUsers.last
        for index in skip..<messages.count {
            let message = messages[index]
            let role = message.role
            let content = message.content
            let notification = role == "user" ? Self.backgroundNotification(content) : nil
            if role == "system" { continue }
            if role == "user" || turn < 0 {
                let title =
                    notification.map { "Background process notification · \($0)" }
                    ?? (role == "user" ? TextPreview.singleLine(content, limit: 140) : "Carried conversation context")
                turn = turns.count
                turns.append(
                    InspectorTurn(
                        id: Identifiers.userTurn(requestAt: record.source.offset, messageIndex: index),
                        title: title.isEmpty ? "User message without text" : title, group: group,
                        observed: record.timestamp, events: []))
            }
            let historical = skip == 0 && (lastSeenUser.map { index < $0 } ?? false)
            let note =
                historical
                ? "Historical context first seen in this request. Original event time is unavailable."
                : "First observed in this request's message history; original message time is unavailable. Conversation continuity is inferred from exact history prefixes."
            let ref = Evidence(source: record.source, messageIndex: index)
            let eventID = Identifiers.messageEvent(requestAt: record.source.offset, messageIndex: index)
            if role == "user" {
                turns[turn].events.append(
                    InspectorEvent(
                        id: eventID, kind: .user,
                        title: notification != nil
                            ? "Background process notification"
                            : (historical ? "Earlier user message" : "User message"),
                        summary: TextPreview.singleLine(content), timestamp: record.timestamp,
                        note: note
                            + (notification != nil
                                ? " The message identifies itself as a Hermes gateway notification, not a human-authored user message."
                                : ""),
                        evidence: ref))
            } else if role == "tool" {
                let toolCallID = message.toolCallID
                let eligible = toolCallID.flatMap { calls["\(group):\($0)"] } ?? []
                let linked =
                    eligible.count == 1 && turns[eligible[0].turn].events[eligible[0].event].linkedEvent == nil
                    ? eligible[0] : nil
                let name = linked.map { turns[$0.turn].events[$0.event].title } ?? "Unmatched tool"
                let result = ToolResultText.summary(content)
                var event = InspectorEvent(
                    id: eventID, kind: .result, title: "\(name) result", summary: result.text,
                    timestamp: record.timestamp,
                    note: note + " This is an agent-reported result, not independent execution telemetry.",
                    evidence: ref, toolID: toolCallID, reportsFailure: result.reportsFailure)
                if let match = linked {
                    event.linkedEvent = turns[match.turn].events[match.event].id
                    turns[match.turn].events[match.event].linkedEvent = eventID
                    turns[match.turn].events[match.event].note +=
                        " Result matched by explicit tool-call ID within the inferred conversation."
                }
                turns[turn].events.append(event)
            } else if role == "assistant" {
                if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                    for (callIndex, call) in toolCalls.enumerated() {
                        let callID = call.id
                        let event = InspectorEvent(
                            id: Identifiers.callEvent(
                                requestAt: record.source.offset, messageIndex: index, callIndex: callIndex),
                            kind: .call,
                            title: call.name,
                            summary: TextPreview.singleLine(call.arguments),
                            timestamp: record.timestamp, note: note + " Structured call reported by the agent.",
                            evidence: Evidence(source: record.source, messageIndex: index, callIndex: callIndex),
                            toolID: callID)
                        if let callID {
                            calls["\(group):\(callID)", default: []].append((turn, turns[turn].events.count))
                        }
                        turns[turn].events.append(event)
                    }
                }
                if !content.isEmpty {
                    turns[turn].events.append(
                        InspectorEvent(
                            id: eventID, kind: .context, title: "Assistant message in history",
                            summary: TextPreview.singleLine(content), timestamp: record.timestamp,
                            note: note + " May repeat a previously observed generated output.", evidence: ref))
                }
            } else {
                turns[turn].events.append(
                    InspectorEvent(
                        id: eventID, kind: .context, title: "\(role.capitalized) message",
                        summary: TextPreview.singleLine(content), timestamp: record.timestamp, note: note, evidence: ref
                    ))
            }
        }
        return turn
    }

    /// Why this request appears to be happening, worded as an inference.
    private func continuationReason(
        for addedMessages: [RequestPayload.Message], matched: Int?, allMessages: [RequestPayload.Message]
    ) -> String {
        let resultMessages = addedMessages.filter { $0.role == "tool" }
        if let user = addedMessages.last(where: { $0.role == "user" }),
            Self.backgroundNotification(user.content) != nil
        {
            return "Responding to a background-process notification"
        } else if matched != nil && addedMessages.isEmpty {
            return "Repeated request history (retry or replay)"
        } else if matched == nil {
            return "Starting this turn"
        } else if addedMessages.contains(where: { $0.role == "user" }) {
            return "Responding to a new user message"
        } else if !resultMessages.isEmpty {
            let names = resultMessages.map { result -> String? in
                guard let id = result.toolCallID else { return nil }
                let matching = allMessages.flatMap { $0.toolCalls ?? [] }.filter { $0.id == id }
                guard matching.count == 1 else { return nil }
                return matching[0].reportedName
            }
            if resultMessages.count == 1 {
                return "Continuing after \(names[0] ?? "a tool") result"
            } else if let first = names[0], names.allSatisfy({ $0 == first }) {
                return "Continuing after \(resultMessages.count) \(first) results"
            } else {
                return "Continuing after \(resultMessages.count) tool results"
            }
        } else {
            return "Continuing with new conversation context"
        }
    }

    /// Request metrics, including a possible-reset comparison candidate when no
    /// exact history prefix matched but one stored head shares this turn's last
    /// user message and at least two message hashes.
    private func requestMetrics(
        model: String, matched: Int?, lastUser: String?, fields: [String: String], hashes: [String], chain: String
    ) -> RequestMetrics {
        var metrics = RequestMetrics(model: model)
        let possible =
            matched == nil
            ? (lastUser.flatMap { historiesByUser[$0] } ?? []).filter {
                let history = histories[$0]
                guard let headHashes = history.headHashes else { return false }
                return lastUser != nil && history.lastUser == lastUser && history.chain != chain
                    && Set(headHashes).intersection(hashes).count >= 2
            } : []
        if let prior = matched ?? (possible.count == 1 ? possible.first : nil) {
            let history = histories[prior]
            metrics.previousRequest = history.requestID
            metrics.comparisonInferred = true
            metrics.possibleReset = matched == nil
            metrics.changedFields = Set(fields.keys).union(history.fields.keys).filter {
                fields[$0] != history.fields[$0]
            }.sorted()
        }
        return metrics
    }

    /// Honest wording for the continuity decision taken above.
    private func continuityExplanation(
        matched: Int?, skip: Int, messageCount: Int, uniqueOrigin: Bool, hasCandidates: Bool, metrics: RequestMetrics
    ) -> String {
        if matched != nil {
            return skip == messageCount
                ? "Identical complete history in one inferred conversation; shown as another inference. A retry cannot be distinguished from a replay."
                : "Continuation inferred from an exact earlier message-history prefix, independent of intervening requests from other streams."
        } else if hasCandidates {
            return uniqueOrigin
                ? "History diverged from an older checkpoint outside a verified user-message branch. Kept separate to avoid joining rewritten histories."
                : "Several earlier histories or different models could explain this request. No unique predecessor; kept separate."
        } else if metrics.possibleReset {
            return
                "History changed, was shortened, or had instructions rewritten. A comparison candidate is available; conversation continuity is unverified."
        } else {
            return
                "No exact earlier message-history prefix was found. This may be a new conversation, changed history, or a conversation that began in another log."
        }
    }

    /// Records the post-request checkpoint, retiring the matched head so only
    /// current heads keep message hashes.
    private mutating func checkpointHistory(
        matched: Int?, hashes: [String], group: Int, turn: Int, requestID: String, fields: [String: String],
        lastUser: String?, chain: String, userPositions: [Int]
    ) {
        let index = histories.count
        if let matched {
            let previous = histories[matched]
            histories[matched].headHashes = nil
            histories[matched].children.append(index)
            if let user = previous.lastUser {
                historiesByUser[user]?.removeAll { $0 == matched }
                if historiesByUser[user]?.isEmpty == true { historiesByUser.removeValue(forKey: user) }
            }
        }
        let history = History(
            headHashes: hashes, count: hashes.count, group: group, turn: turn, requestID: requestID, fields: fields,
            lastUser: lastUser, chain: chain, userPositions: Set(userPositions))
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
                users.contains(common), history.userPositions.contains(common)
            else { return false }
            foundHead = true
        }
        return foundHead
    }
    private static func backgroundNotification(_ content: String) -> String? {
        guard content.contains(LogGrammar.backgroundNotificationMarker)
        else { return nil }
        return LogGrammar.backgroundProcess.captures(in: content)?.first
    }
    /// Parses oMLX log timestamps in the local time zone, as the log writes them.
    ///
    /// Creating a `DateFormatter` is expensive and this runs during indexing and view updates,
    /// so one instance is shared. `DateFormatter` is thread-safe for parsing on Apple platforms
    /// (macOS 10.9 and later), and this one is never mutated after initialization. The wrapper
    /// states that explicitly, whether or not the SDK marks `DateFormatter` as `Sendable`.
    private final class TimestampParser: @unchecked Sendable {
        private let formatter: DateFormatter

        init() {
            formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss,SSS"
        }

        func date(from timestamp: String) -> Date? { formatter.date(from: timestamp) }
    }
    private static let timestampParser = TimestampParser()

    /// Signed seconds from one log timestamp to another, or `nil` if either cannot be parsed.
    static func elapsedSeconds(from start: String, to end: String) -> Double? {
        guard let begin = timestampParser.date(from: start), let finish = timestampParser.date(from: end) else {
            return nil
        }
        return finish.timeIntervalSince(begin)
    }
    /// Final pass after the last record: sorts warnings and annotates calls without a matched result.
    mutating func finish() {
        warnings = Array(Set(warnings)).sorted()
        for turnIndex in turns.indices {
            for eventIndex in turns[turnIndex].events.indices
            where turns[turnIndex].events[eventIndex].kind == .call
                && turns[turnIndex].events[eventIndex].linkedEvent == nil
            {
                turns[turnIndex].events[eventIndex].note += " Result not observed or not uniquely matchable."
            }
        }
    }
}
