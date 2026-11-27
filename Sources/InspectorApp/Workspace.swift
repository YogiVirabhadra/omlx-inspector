import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import InspectorCore
#endif

@MainActor @Observable final class Workspace {
    var snapshot: LogSnapshot? { didSet { updateDisplay() } }
    var displayBoundary: DisplayBoundary? { didSet { updateDisplay() } }
    private(set) var displaySnapshot: LogSnapshot?
    private func updateDisplay() {
        displaySnapshot = snapshot.map { displayBoundary?.applying(to: $0) ?? $0 }
        recordLoggers = Array(Set(snapshot?.records.map(\.logger) ?? [])).sorted()
        updateRecords()
    }
    func isDisplayed(_ event: InspectorEvent) -> Bool {
        guard let snapshot else { return false }
        return displayBoundary?.includes(event, generation: snapshot.generation) ?? true
    }
    func clearDisplay() {
        guard let snapshot, !loading, pendingReplacement == nil else { return }
        detailTask?.cancel(); searchTask?.cancel()
        displayBoundary = DisplayBoundary(snapshot: snapshot)
        remembered = [:]; turnID = nil; eventID = nil; recordID = nil; detail = nil; detailError = nil; detailLoading = false
        searchPresented = false; searchResults = nil; recordSearchResults = nil; searching = false; searchError = nil
        timelinePage = 0; recordPage = 0; newEvents = 0; completionSource = false
        recordLevel = "All levels"; recordLogger = "All loggers"
        monitoring = true; filter = .all; following = true
    }
    func showHistory() {
        displayBoundary = nil; following = false; newEvents = 0
        searchTask?.cancel(); searching = false; searchResults = nil
        if turn == nil { turnID = snapshot?.turns.last?.id; selectTurn() }
        if browsingMode == "Log Records" { selectRecord() }
    }
    private func revealHiddenEvent(_ id: String) {
        if let event = snapshot?.turns.lazy.flatMap(\.events).first(where: { $0.id == id }), !isDisplayed(event) {
            showHistory()
        }
    }
    var turnID: String?
    var eventID: String?
    var browsingMode = UserDefaults.standard.string(forKey: "browsingMode") ?? "Executions" {
        didSet {
            UserDefaults.standard.set(browsingMode, forKey: "browsingMode")
            following = false; newEvents = 0
            searchTask?.cancel(); searching = false; searchResults = nil; recordSearchResults = nil; searchError = nil
            if browsingMode == "Log Records" {
                inspector = true
                if selectedRecord == nil { recordID = filteredRecords.first?.id }
                selectRecord()
            } else { selectEvent() }
        }
    }
    var recordID: String?
    var recordMode = UserDefaults.standard.string(forKey: "recordMode") ?? "Structured" {
        didSet { UserDefaults.standard.set(recordMode, forKey: "recordMode") }
    }
    var recordLevel = "All levels" { didSet { recordFilterChanged() } }
    var recordLogger = "All loggers" { didSet { recordFilterChanged() } }
    private(set) var recordLoggers: [String] = []
    private(set) var filteredRecords: [IndexedLogRecord] = []
    var recordPage = 0
    var recordNavigation = 0
    var recordSearchResults: RecordSearchResults?
    var relatedNavigation = 0
    var detail: EventDetail?
    var loading = false
    var detailLoading = false
    var error: String?
    var detailError: String?
    var inspector = true
    var showContext = UserDefaults.standard.bool(forKey: "showContext") { didSet { savePreferences() } }
    var appearance = UserDefaults.standard.string(forKey: "appearance") ?? "System" { didSet { savePreferences() } }
    var mode = UserDefaults.standard.string(forKey: "mode") ?? "Readable" { didSet { savePreferences() } }
    private(set) var filter = EventFilter(rawValue: UserDefaults.standard.string(forKey: "filter") ?? "") ?? .all { didSet { savePreferences() } }
    var monitoring = UserDefaults.standard.object(forKey: "monitoring") as? Bool ?? true { didSet { savePreferences() } }
    var following = false
    var newEvents = 0
    var monitorStatus = ""
    var recoveryNotice: String?
    var rotatedSources: [URL] = []
    var pendingReplacement: LogSnapshot?
    var structuredStates: [String: StructuredViewState] = [:]
    var completionSource = false
    var visibleCharacters = 80000
    var loadSeconds: Double = 0
    var query = ""
    var searchPresented = false
    var searchResults: SearchResults?
    var searching = false
    var searchError: String?
    var searchGeneration: String?
    var searchSize: UInt64?
    var timelinePage = 0
    let pageSize = 200
    private var task: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var session: LogSession?
    private var remembered: [String: String] = [:]
    private var restored = false
    var turn: InspectorTurn? { snapshot?.turns.first { $0.id == turnID } }
    var event: InspectorEvent? { turn?.events.first { $0.id == eventID } }
    var selectedRecord: IndexedLogRecord? { snapshot?.records.first { $0.id == recordID } }
    var recordPageCount: Int { max(1, (filteredRecords.count + pageSize - 1) / pageSize) }
    var pagedRecords: [IndexedLogRecord] { Array(filteredRecords.dropFirst(recordPage * pageSize).prefix(pageSize)) }
    var recordText: String { recordMode == "Source" ? detail?.raw ?? "" : detail?.structured ?? "" }
    private func updateRecords() {
        filteredRecords = displaySnapshot?.records.filter { (recordLevel == "All levels" || $0.level == recordLevel) && (recordLogger == "All loggers" || $0.logger == recordLogger) } ?? []
        recordPage = min(recordPage, recordPageCount - 1)
    }
    private func recordFilterChanged() {
        following = false; recordPage = 0; updateRecords()
        if !filteredRecords.contains(where: { $0.id == recordID }) {
            recordID = filteredRecords.first?.id
            if browsingMode == "Log Records" { selectRecord() }
        }
        revealRecordPage(); recordNavigation += 1
    }
    var visibleEvents: [InspectorEvent] { turn?.events.filter { isDisplayed($0) && (showContext || $0.kind != .context) && filter.includes($0) } ?? [] }
    var pageCount: Int { max(1, (visibleEvents.count + pageSize - 1) / pageSize) }
    var visibleCycles: [TimelineCycle] {
        let ids = Set(visibleEvents.dropFirst(timelinePage * pageSize).prefix(pageSize).map(\.id))
        return turn?.timelineCycles(showContext: showContext).compactMap { c in
            var c = c; c.events = c.events.filter { ids.contains($0.id) }; return c.events.isEmpty ? nil : c
        } ?? []
    }
    var text: String {
        guard let detail else { return "" }
        if mode == "Source" { return completionSource ? detail.completionRaw ?? detail.raw : detail.raw }
        if mode == "Structured" { return detail.structured }
        return detail.readable
    }
    func savePreferences() {
        let defaults = UserDefaults.standard
        defaults.set(appearance, forKey: "appearance"); defaults.set(mode, forKey: "mode")
        defaults.set(showContext, forKey: "showContext"); defaults.set(filter.rawValue, forKey: "filter")
        defaults.set(monitoring, forKey: "monitoring")
    }
    func restore() {
        guard !restored else { return }; restored = true
        if let path = UserDefaults.standard.string(forKey: "lastSource"), FileManager.default.fileExists(atPath: path) { load(URL(fileURLWithPath: path), restoring: true) }
    }
    func open() {
        let panel = NSOpenPanel(); panel.title = "Open an oMLX log"
        panel.message = "The source is read-only. Monitoring reads new records while this app is open."
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.directoryURL = snapshot?.url.deletingLastPathComponent() ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".omlx/logs")
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }
    func load(_ url: URL, restoring: Bool = false) {
        task?.cancel(); monitorTask?.cancel(); detailTask?.cancel(); searchTask?.cancel()
        searching = false; loading = true; error = nil; following = false; pendingReplacement = nil
        recoveryNotice = nil; monitorStatus = "Indexing…"; newEvents = 0
        let newSession = LogSession(url: url); session = newSession
        task = Task {
            let start = Date()
            do {
                guard let update = try await newSession.refresh(), !Task.isCancelled else { return }
                displayBoundary = nil
                snapshot = update.snapshot; remembered = [:]; structuredStates = [:]; detail = nil; eventID = nil
                searchResults = nil; recordSearchResults = nil; timelinePage = 0; recordPage = 0
                recordID = filteredRecords.first?.id
                if restoring, UserDefaults.standard.string(forKey: "recordInode") == String(update.snapshot.inode),
                   let saved = UserDefaults.standard.string(forKey: "selectedRecord"),
                   let record = filteredRecords.first(where: { $0.id == saved && $0.source.digest == UserDefaults.standard.string(forKey: "recordDigest") }) {
                    recordID = record.id
                }
                if restoring,
                   UserDefaults.standard.string(forKey: "selectedInode") == String(update.snapshot.inode),
                   let saved = UserDefaults.standard.string(forKey: "selectedEvent"),
                   let turn = update.snapshot.turns.first(where: { $0.events.contains(where: { $0.id == saved && $0.evidence.source.digest == UserDefaults.standard.string(forKey: "selectedDigest") }) }) {
                    remembered[turn.id] = saved; turnID = turn.id
                } else { turnID = update.snapshot.turns.first(where: { $0.requests > 1 })?.id ?? update.snapshot.turns.first?.id }
                loadSeconds = Date().timeIntervalSince(start); loading = false; selectTurn()
                if browsingMode == "Log Records" { revealRecordPage(); selectRecord() }
                UserDefaults.standard.set(url.path, forKey: "lastSource")
                monitorStatus = "Up to date"
                startMonitoring(newSession)
            } catch {
                guard !Task.isCancelled else { return }
                var message = error.localizedDescription
                if case InspectorError.recordTooLarge = error, snapshot != nil {
                    message += " The previously displayed snapshot remains available."
                }
                self.error = message; loading = false; monitorStatus = "Indexing stopped"
            }
        }
    }
    func cancel() { task?.cancel(); loading = false }
    private func startMonitoring(_ current: LogSession) {
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                guard self.monitoring else { continue }
                do {
                    let update = try await current.refresh()
                    guard !Task.isCancelled else { return }
                    self.monitorStatus = "Up to date"
                    if let update { self.apply(update) }
                } catch {
                    guard !Task.isCancelled else { return }
                    if case InspectorError.recordTooLarge = error {
                        self.monitoring = false
                        self.monitorStatus = error.localizedDescription
                    } else {
                        self.monitorStatus = "Waiting for source · " + error.localizedDescription
                    }
                }
            }
        }
    }
    private func apply(_ update: IndexUpdate) {
        if pendingReplacement != nil { pendingReplacement = update.snapshot; return }
        if update.reset {
            recoveryNotice = update.recovery
            if let old = snapshot {
                let directory = old.url.deletingLastPathComponent()
                if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
                   let rotated = files.first(where: { candidate in
                       guard candidate != old.url, let attrs = try? FileManager.default.attributesOfItem(atPath: candidate.path) else { return false }
                       return (attrs[.systemFileNumber] as? NSNumber)?.uint64Value == old.inode
                   }) {
                    var archived = old; archived.url = rotated; snapshot = archived
                    if !rotatedSources.contains(rotated) { rotatedSources.append(rotated) }
                }
            }
            if !following { pendingReplacement = update.snapshot; return }
            adopt(update.snapshot); followLatest(); return
        }
        let oldEvent = event
        let oldRecord = selectedRecord
        let oldCount = browsingMode == "Log Records" ? displaySnapshot?.records.count ?? 0 : displaySnapshot?.turns.reduce(0, { $0 + $1.events.count }) ?? 0
        snapshot = update.snapshot
        let newCount = browsingMode == "Log Records" ? displaySnapshot?.records.count ?? 0 : displaySnapshot?.turns.reduce(0, { $0 + $1.events.count }) ?? 0
        newEvents += max(0, newCount - oldCount)
        if following { followLatest() }
        else if browsingMode == "Log Records" {
            if selectedRecord?.source != oldRecord?.source { selectRecord() }
        }
        else if event == nil, let turn { eventID = turn.events.last?.id; selectEvent() }
        else if event?.evidence != oldEvent?.evidence || event?.metrics != oldEvent?.metrics || event?.completion != oldEvent?.completion || event?.linkedEvent != oldEvent?.linkedEvent { selectEvent() }
    }
    private func adopt(_ next: LogSnapshot) {
        displayBoundary = nil
        snapshot = next; pendingReplacement = nil; remembered = [:]; structuredStates = [:]
        searchTask?.cancel(); searching = false; searchResults = nil; detail = nil
        turnID = next.turns.last?.id; eventID = nil; timelinePage = 0; selectTurn()
        recordID = filteredRecords.first?.id; recordPage = 0
        if browsingMode == "Log Records" { selectRecord() }
    }
    func openCurrentGeneration() {
        guard let next = pendingReplacement else { return }
        adopt(next); recoveryNotice = nil
    }
    func setFilter(_ category: EventFilter) {
        following = false
        filter = category
        timelinePage = 0
    }
    func followLatest() {
        if pendingReplacement != nil { openCurrentGeneration() }
        if browsingMode == "Log Records" {
            recordLevel = "All levels"; recordLogger = "All loggers"
            following = true; newEvents = 0
            recordID = filteredRecords.last?.id; revealRecordPage(); recordNavigation += 1; selectRecord()
            return
        }
        filter = .all; following = true; newEvents = 0; timelinePage = 0
        guard let latest = displaySnapshot?.turns.flatMap({ t in t.events.map { (t.id, $0) } }).max(by: { a, b in
            if a.1.evidence.source.offset == b.1.evidence.source.offset { return a.1.id < b.1.id }
            return a.1.evidence.source.offset < b.1.evidence.source.offset
        }) else { return }
        remembered[latest.0] = latest.1.id; turnID = latest.0; eventID = latest.1.id
        revealPage(); relatedNavigation += 1; selectEvent()
    }
    func selectTurn() {
        guard let turn else { eventID = nil; return }
        eventID = remembered[turn.id] ?? visibleEvents.first?.id ?? turn.events.first?.id
        revealPage(); selectEvent()
    }
    func clickEvent(_ event: InspectorEvent) { following = false; eventID = event.id }
    func revealPage() {
        if let index = visibleEvents.firstIndex(where: { $0.id == eventID }) { timelinePage = index / pageSize }
        else { timelinePage = 0 }
    }
    func selectEvent() {
        guard browsingMode == "Executions" else { return }
        detailTask?.cancel(); detail = nil; detailError = nil; visibleCharacters = 80000; completionSource = false
        guard let event, let snapshot else { detailLoading = false; return }
        if let turnID { remembered[turnID] = event.id }
        let defaults = UserDefaults.standard
        defaults.set(event.id, forKey: "selectedEvent"); defaults.set(String(snapshot.inode), forKey: "selectedInode")
        defaults.set(event.evidence.source.digest, forKey: "selectedDigest")
        detailLoading = true
        detailTask = Task {
            do {
                let worker = Task.detached(priority: .userInitiated) { try LogReader.detail(event, snapshot: snapshot) }
                let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled else { return }
                if structuredStates[event.id] == nil { structuredStates[event.id] = StructuredViewState() }
                detail = value; detailLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                detailError = error.localizedDescription; detailLoading = false
            }
        }
    }
    func related() {
        guard let id = event?.linkedEvent, let t = snapshot?.turns.first(where: { $0.events.contains { $0.id == id } }) else { return }
        revealHiddenEvent(id)
        following = false; filter = .all; remembered[t.id] = id; turnID = t.id; eventID = id
        revealPage(); relatedNavigation += 1; selectEvent()
    }
    func previousRequest() {
        guard let id = event?.metrics?.previousRequest, let t = snapshot?.turns.first(where: { $0.events.contains { $0.id == id } }) else { return }
        revealHiddenEvent(id)
        following = false; filter = .all; remembered[t.id] = id; turnID = t.id; eventID = id
        revealPage(); relatedNavigation += 1; selectEvent()
    }
    func runSearch() {
        searchTask?.cancel(); searchResults = nil; recordSearchResults = nil; searchError = nil
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let snapshot = displaySnapshot, !text.isEmpty else { searching = false; return }
        searching = true; following = false; searchGeneration = snapshot.generation; searchSize = snapshot.size
        if browsingMode == "Log Records" {
            let records = filteredRecords
            searchTask = Task {
                do {
                    try await Task.sleep(for: .milliseconds(300))
                    let worker = Task.detached(priority: .userInitiated) { try LogReader.searchRecords(text, snapshot: snapshot, records: records) }
                    let results = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    guard !Task.isCancelled else { return }
                    recordSearchResults = results; searching = false
                } catch {
                    guard !Task.isCancelled else { return }
                    searchError = error.localizedDescription; searching = false
                }
            }
            return
        }
        searchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(300))
                let worker = Task.detached(priority: .userInitiated) { try LogReader.search(text, snapshot: snapshot) }
                let results = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled else { return }
                searchResults = results; searching = false
            } catch {
                guard !Task.isCancelled else { return }
                searchError = error.localizedDescription; searching = false
            }
        }
    }
    func navigate(_ hit: SearchHit) {
        guard searchGeneration == snapshot?.generation else { searchError = "The source changed. Search again before opening a result."; return }
        following = false; filter = .all
        if hit.event.kind == .context { showContext = true }
        remembered[hit.turnID] = hit.event.id; turnID = hit.turnID; eventID = hit.event.id
        revealPage(); relatedNavigation += 1; searchPresented = false; selectEvent()
    }
    func copy() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    func selectRecord() {
        guard browsingMode == "Log Records" else { return }
        detailTask?.cancel(); detail = nil; detailError = nil; visibleCharacters = 80000
        guard let record = selectedRecord, let snapshot else { detailLoading = false; return }
        let defaults = UserDefaults.standard
        defaults.set(record.id, forKey: "selectedRecord"); defaults.set(String(snapshot.inode), forKey: "recordInode")
        defaults.set(record.source.digest, forKey: "recordDigest")
        detailLoading = true
        detailTask = Task {
            do {
                let worker = Task.detached(priority: .userInitiated) { try LogReader.detail(record, snapshot: snapshot) }
                let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled else { return }
                if structuredStates[record.id] == nil { structuredStates[record.id] = StructuredViewState() }
                detail = value; detailLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                detailError = error.localizedDescription; detailLoading = false
            }
        }
    }
    func revealRecordPage() {
        if let index = filteredRecords.firstIndex(where: { $0.id == recordID }) { recordPage = index / pageSize }
        else { recordPage = 0 }
    }
    func viewLogRecord(completion: Bool = false) {
        guard let event, let snapshot, let record = snapshot.record(containing: event, completion: completion) else { return }
        if displayBoundary?.includes(record, generation: snapshot.generation) == false { showHistory() }
        recordLevel = "All levels"; recordLogger = "All loggers"
        browsingMode = "Log Records"; inspector = true; recordID = record.id
        revealRecordPage(); recordNavigation += 1; selectRecord()
    }
    func navigateRecord(_ hit: RecordSearchHit) {
        guard searchGeneration == snapshot?.generation else { searchError = "The source changed. Search again before opening a result."; return }
        following = false; recordID = hit.record.id; revealRecordPage(); recordNavigation += 1
        searchPresented = false; selectRecord()
    }
    func copyRecord() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(recordText, forType: .string) }
}
