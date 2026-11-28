import SwiftUI
import AppKit
#if SWIFT_PACKAGE
    import InspectorCore
#endif

/// The application's single source of UI state: the open log, its live monitor, selection,
/// search, and persisted preferences.
///
/// File I/O and parsing run off the main actor (in ``LogSession`` and detached tasks); their
/// results are applied here. Each long-running task is cancelled before it is replaced, and
/// results are discarded if their task was cancelled, so stale work never overwrites newer state.
///
/// Selection changes go through the methods in the Selection section, which load the matching
/// detail exactly once. Views read the selection but never assign it directly.
@MainActor @Observable final class Workspace {
    /// Characters of a long representation shown at once; "Load more" adds this many again.
    nonisolated static let textPageCharacters = 80_000
    /// Events or records per timeline or record-list page.
    let pageSize = 200

    // MARK: - Preferences

    private let defaults: UserDefaults
    var appearance: Appearance { didSet { savePreferences() } }
    /// The Inspector representation for events.
    var mode: InspectorMode { didSet { savePreferences() } }
    var showContext: Bool {
        didSet {
            savePreferences()
            keepEventSelectionVisible()
        }
    }
    private(set) var filter: EventFilter { didSet { savePreferences() } }
    /// Whether appended data is read while the app is open. Independent of ``following``.
    var monitoring: Bool { didSet { savePreferences() } }
    var browsingMode: BrowsingMode {
        didSet {
            defaults.set(browsingMode.rawValue, for: .browsingMode)
            following = false
            newEvents = 0
            resetSearchState(dismiss: true)
            if browsingMode == .logRecords {
                inspector = true
                if selectedRecord == nil { recordID = filteredRecords.first?.id }
                loadSelectedRecordDetail()
            } else {
                loadSelectedEventDetail()
            }
        }
    }
    var recordMode: RecordInspectorMode {
        didSet { defaults.set(recordMode.rawValue, for: .recordMode) }
    }

    // MARK: - Source

    /// The most recent complete index of the open log.
    var snapshot: LogSnapshot? { didSet { updateDisplay() } }
    /// Set by Clear Display; hides activity that existed when it was captured.
    var displayBoundary: DisplayBoundary? { didSet { updateDisplay() } }
    /// ``snapshot`` with ``displayBoundary`` applied. Views read this one.
    private(set) var displaySnapshot: LogSnapshot?
    /// A new source generation (after rotation or truncation) waiting for the user to open it
    /// while they browse the previous one.
    var pendingReplacement: LogSnapshot?
    /// Earlier files of the same log, found after rotation.
    var rotatedSources: [URL] = []
    var loading = false
    var error: String?
    var recoveryNotice: String?
    var monitorStatus = ""
    var loadSeconds: Double = 0

    // MARK: - Live activity

    /// Whether the selection tracks the newest activity. Independent of ``monitoring``.
    var following = false
    /// Activity that arrived while not following, shown on the "Return to Live" button.
    var newEvents = 0

    // MARK: - Selection

    private(set) var turnID: String?
    private(set) var eventID: String?
    private(set) var recordID: String?
    /// The last selected event in each turn, keyed by turn ID.
    private var remembered: [String: String] = [:]
    var timelinePage = 0
    var recordPage = 0
    /// Incremented to ask the timeline to scroll the selection into view.
    var relatedNavigation = 0
    /// Incremented to ask the record list to scroll the selection into view.
    var recordNavigation = 0
    var recordLevel: RecordLevel = .all { didSet { recordFilterChanged() } }
    var recordLogger: LoggerFilter = .all { didSet { recordFilterChanged() } }
    private(set) var recordLoggers: [String] = []
    private(set) var filteredRecords = RecordList()

    // MARK: - Inspector

    var inspector = true
    var detail: EventDetail?
    var detailLoading = false
    var detailError: String?
    /// In Source mode, show the associated completion record instead of the event's own.
    var completionSource = false
    var visibleCharacters = Workspace.textPageCharacters
    /// Outline expansion and selection, remembered per event or record ID.
    var structuredStates: [String: StructuredViewState] = [:]

    // MARK: - Search

    var query = ""
    var searchPresented = false
    var searching = false
    var searchResults: SearchResults?
    var recordSearchResults: RecordSearchResults?
    var searchError: String?
    /// The generation and size the current results were computed from.
    var searchGeneration: String?
    var searchSize: UInt64?

    // MARK: - Tasks

    private var task: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    /// The session the live monitor reads. Kept so that monitoring of the log still on screen
    /// can resume when a replacement load is cancelled or fails.
    private var monitoredSession: LogSession?
    private var searchTask: Task<Void, Never>?
    private var restored = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        browsingMode = BrowsingMode(rawValue: defaults.string(for: .browsingMode) ?? "") ?? .executions
        recordMode = RecordInspectorMode(rawValue: defaults.string(for: .recordMode) ?? "") ?? .structured
        appearance = Appearance(rawValue: defaults.string(for: .appearance) ?? "") ?? .system
        mode = InspectorMode(rawValue: defaults.string(for: .mode) ?? "") ?? .readable
        showContext = defaults.bool(for: .showContext)
        filter = EventFilter(rawValue: defaults.string(for: .filter) ?? "") ?? .all
        monitoring = defaults.object(for: .monitoring) as? Bool ?? true
    }

    // MARK: - Derived state

    var turn: InspectorTurn? { snapshot?.turns.first { $0.id == turnID } }
    var event: InspectorEvent? { turn?.events.first { $0.id == eventID } }
    var selectedRecord: IndexedLogRecord? { recordID.flatMap { snapshot?.records.record(withID: $0) } }
    var visibleEvents: [InspectorEvent] {
        turn?.events.filter { isDisplayed($0) && (showContext || $0.kind != .context) && filter.includes($0) } ?? []
    }
    var pageCount: Int { max(1, (visibleEvents.count + pageSize - 1) / pageSize) }
    var visibleCycles: [TimelineCycle] {
        let ids = Set(visibleEvents.dropFirst(timelinePage * pageSize).prefix(pageSize).map(\.id))
        return turn?.timelineCycles(showContext: showContext).compactMap { cycle in
            var visible = cycle
            visible.events = cycle.events.filter { ids.contains($0.id) }
            return visible.events.isEmpty ? nil : visible
        } ?? []
    }
    var recordPageCount: Int { max(1, (filteredRecords.count + pageSize - 1) / pageSize) }
    var pagedRecords: [IndexedLogRecord] { Array(filteredRecords.dropFirst(recordPage * pageSize).prefix(pageSize)) }
    /// The event Inspector's current representation, complete.
    var text: String {
        guard let detail else { return "" }
        switch mode {
        case .source: return completionSource ? detail.completionRaw ?? detail.raw : detail.raw
        case .structured: return detail.structured
        case .readable: return detail.readable
        }
    }
    /// The record Inspector's current representation, complete.
    var recordText: String { recordMode == .source ? detail?.raw ?? "" : detail?.structured ?? "" }

    func isDisplayed(_ event: InspectorEvent) -> Bool {
        guard let snapshot else { return false }
        return displayBoundary?.includes(event, generation: snapshot.generation) ?? true
    }

    func savePreferences() {
        defaults.set(appearance.rawValue, for: .appearance)
        defaults.set(mode.rawValue, for: .mode)
        defaults.set(showContext, for: .showContext)
        defaults.set(filter.rawValue, for: .filter)
        defaults.set(monitoring, for: .monitoring)
    }

    private func updateDisplay() {
        displaySnapshot = snapshot.map { displayBoundary?.applying(to: $0) ?? $0 }
        recordLoggers = snapshot?.loggers ?? []
        updateRecords()
    }

    private func updateRecords() {
        let records = displaySnapshot?.records ?? RecordList()
        // The lazy filter stores its closure, so capture the filter values rather than `self`.
        let level = recordLevel
        let logger = recordLogger
        // Unfiltered is the common case while following; share the snapshot's storage instead of copying it.
        filteredRecords =
            level == .all && logger == .all
            ? records : RecordList(records.lazy.filter { level.includes($0.level) && logger.includes($0.logger) })
        recordPage = min(recordPage, recordPageCount - 1)
    }

    // MARK: - Resetting

    /// Cancels both search modes and invalidates their snapshot provenance.
    private func resetSearchState(dismiss: Bool = false) {
        searchTask?.cancel()
        searchTask = nil
        searching = false
        searchResults = nil
        recordSearchResults = nil
        searchError = nil
        searchGeneration = nil
        searchSize = nil
        if dismiss { searchPresented = false }
    }

    private func resetDetail() {
        detailTask?.cancel()
        detailTask = nil
        detail = nil
        detailError = nil
        detailLoading = false
        visibleCharacters = Self.textPageCharacters
        completionSource = false
    }

    private func resetSelection() {
        resetDetail()
        remembered = [:]
        turnID = nil
        eventID = nil
        recordID = nil
        timelinePage = 0
        recordPage = 0
    }

    /// Also used by the test harness to finish without leaving a monitor running.
    func stop() {
        task?.cancel()
        monitorTask?.cancel()
        task = nil
        monitorTask = nil
        monitoredSession = nil
        loading = false
        resetSearchState(dismiss: true)
        resetDetail()
    }
}

// MARK: - Opening and monitoring

extension Workspace {
    /// Reopens the last log at launch, once.
    func restore() {
        guard !restored else { return }
        restored = true
        if let path = defaults.string(for: .lastSource), FileManager.default.fileExists(atPath: path) {
            load(URL(fileURLWithPath: path), restoring: true)
        }
    }

    func open() {
        let panel = NSOpenPanel()
        panel.title = "Open an oMLX log"
        panel.message = "The source is read-only. Monitoring reads new records while this app is open."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL =
            snapshot?.url.deletingLastPathComponent()
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".omlx/logs")
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    /// Indexes `url` from scratch and, on success, replaces the snapshot and starts monitoring.
    ///
    /// - Parameter restoring: Restore the selection saved by the previous launch.
    func load(_ url: URL, restoring: Bool = false) {
        task?.cancel()
        monitorTask?.cancel()
        resetDetail()
        resetSearchState(dismiss: true)
        loading = true
        error = nil
        following = false
        pendingReplacement = nil
        recoveryNotice = nil
        monitorStatus = "Indexing…"
        newEvents = 0
        let newSession = LogSession(url: url)
        task = Task {
            let start = Date()
            do {
                guard let update = try await newSession.refresh(), !Task.isCancelled else { return }
                displayBoundary = nil
                snapshot = update.snapshot
                remembered = [:]
                structuredStates = [:]
                detail = nil
                eventID = nil
                searchResults = nil
                recordSearchResults = nil
                timelinePage = 0
                recordPage = 0
                recordID = restoring ? savedRecordID(in: update.snapshot) : nil
                recordID = recordID ?? filteredRecords.first?.id
                if restoring, let saved = savedEventLocation(in: update.snapshot) {
                    remembered[saved.turnID] = saved.eventID
                    turnID = saved.turnID
                } else {
                    turnID =
                        update.snapshot.turns.first(where: { $0.requestCount > 1 })?.id
                        ?? update.snapshot.turns.first?.id
                }
                loadSeconds = Date().timeIntervalSince(start)
                loading = false
                showSelectedTurn()
                if browsingMode == .logRecords {
                    revealRecordPage()
                    loadSelectedRecordDetail()
                }
                defaults.set(url.path, for: .lastSource)
                monitorStatus = "Up to date"
                startMonitoring(newSession)
            } catch {
                guard !Task.isCancelled else { return }
                var message = error.localizedDescription
                if case InspectorError.recordTooLarge = error, snapshot != nil {
                    message += " The previously displayed snapshot remains available."
                }
                self.error = message
                loading = false
                monitorStatus = "Indexing stopped"
                resumeMonitoringAfterInterruptedLoad()
            }
        }
    }

    func cancel() {
        guard loading else { return }
        task?.cancel()
        loading = false
        resumeMonitoringAfterInterruptedLoad()
    }

    func openCurrentGeneration() {
        guard let next = pendingReplacement else { return }
        adopt(next)
        recoveryNotice = nil
    }

    /// The record selected at the last launch, if it is in `snapshot` with the same content.
    private func savedRecordID(in snapshot: LogSnapshot) -> String? {
        guard defaults.string(for: .recordInode) == String(snapshot.inode),
            let saved = defaults.string(for: .selectedRecord),
            let record = filteredRecords.record(withID: saved),
            record.source.digest == defaults.string(for: .recordDigest)
        else { return nil }
        return record.id
    }

    /// The event selected at the last launch, if it is in `snapshot` with the same content.
    private func savedEventLocation(in snapshot: LogSnapshot) -> (turnID: String, eventID: String)? {
        guard defaults.string(for: .selectedInode) == String(snapshot.inode),
            let saved = defaults.string(for: .selectedEvent),
            let turn = snapshot.turns.first(where: {
                $0.events.contains(where: {
                    $0.id == saved && $0.evidence.source.digest == defaults.string(for: .selectedDigest)
                })
            })
        else { return nil }
        return (turn.id, saved)
    }

    /// `load(_:)` stops the monitor before indexing. If that load never replaces the snapshot,
    /// resume monitoring the log that is still displayed, so "Monitoring" stays true.
    private func resumeMonitoringAfterInterruptedLoad() {
        guard snapshot != nil, let monitoredSession else { return }
        monitorStatus = "Up to date"
        startMonitoring(monitoredSession)
    }

    private func startMonitoring(_ current: LogSession) {
        monitorTask?.cancel()
        monitoredSession = current
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

    /// Applies a monitor update: appended activity in place, or a new source generation.
    private func apply(_ update: IndexUpdate) {
        if pendingReplacement != nil {
            pendingReplacement = update.snapshot
            return
        }
        if update.reset {
            applyNewGeneration(update)
            return
        }
        let oldEvent = event
        let oldRecord = selectedRecord
        let oldCount = displayedActivityCount
        snapshot = update.snapshot
        newEvents += max(0, displayedActivityCount - oldCount)
        if following {
            followLatest()
        } else if browsingMode == .logRecords {
            if selectedRecord?.source != oldRecord?.source { loadSelectedRecordDetail() }
        } else if event == nil, let turn {
            eventID = turn.events.last?.id
            loadSelectedEventDetail()
        } else if event?.evidence != oldEvent?.evidence || event?.metrics != oldEvent?.metrics
            || event?.completion != oldEvent?.completion || event?.linkedEvent != oldEvent?.linkedEvent
        {
            loadSelectedEventDetail()
        }
    }

    /// Records in Log Records mode, events otherwise.
    private var displayedActivityCount: Int {
        browsingMode == .logRecords
            ? displaySnapshot?.records.count ?? 0 : displaySnapshot?.turns.reduce(0, { $0 + $1.events.count }) ?? 0
    }

    /// The log was replaced, truncated, or rewritten. Keep the old snapshot readable (from its
    /// rotated file, when one is found) and either adopt the new generation now, while
    /// following, or offer it.
    private func applyNewGeneration(_ update: IndexUpdate) {
        recoveryNotice = update.recovery
        if let old = snapshot {
            let directory = old.url.deletingLastPathComponent()
            if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
                let rotated = files.first(where: { candidate in
                    guard candidate != old.url,
                        let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path)
                    else { return false }
                    return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value == old.inode
                })
            {
                var archived = old
                archived.url = rotated
                snapshot = archived
                if !rotatedSources.contains(rotated) { rotatedSources.append(rotated) }
            }
        }
        if !following {
            pendingReplacement = update.snapshot
            return
        }
        adopt(update.snapshot)
        followLatest()
    }

    private func adopt(_ next: LogSnapshot) {
        displayBoundary = nil
        snapshot = next
        pendingReplacement = nil
        remembered = [:]
        structuredStates = [:]
        resetSearchState(dismiss: true)
        resetSelection()
        turnID = next.turns.last?.id
        showSelectedTurn()
        recordID = filteredRecords.first?.id
        if browsingMode == .logRecords { loadSelectedRecordDetail() }
    }
}

// MARK: - Display boundary and following

extension Workspace {
    /// Hides all current activity and follows whatever arrives next. The log is untouched.
    func clearDisplay() {
        guard let snapshot, !loading, pendingReplacement == nil else { return }
        resetSearchState(dismiss: true)
        resetSelection()
        displayBoundary = DisplayBoundary(snapshot: snapshot)
        recordLevel = .all
        recordLogger = .all
        monitoring = true
        filter = .all
        enterLiveFollow()
    }

    /// Removes the Clear Display boundary.
    func showHistory() {
        displayBoundary = nil
        following = false
        newEvents = 0
        resetSearchState(dismiss: true)
        if turn == nil {
            turnID = snapshot?.turns.last?.id
            showSelectedTurn()
        }
        if browsingMode == .logRecords {
            if selectedRecord == nil { recordID = filteredRecords.first?.id }
            revealRecordPage()
            loadSelectedRecordDetail()
        }
    }

    /// Selects the newest event or record and keeps following new activity.
    func followLatest() {
        if pendingReplacement != nil { openCurrentGeneration() }
        if browsingMode == .logRecords {
            recordLevel = .all
            recordLogger = .all
            enterLiveFollow()
            recordID = filteredRecords.last?.id
            revealRecordPage()
            recordNavigation += 1
            loadSelectedRecordDetail()
            return
        }
        filter = .all
        enterLiveFollow()
        timelinePage = 0
        // The newest event is the last one from the furthest record. One request record yields
        // several events (the messages it carried, then the request itself), in that order.
        var latest: (turnID: String, event: InspectorEvent)?
        for turn in displaySnapshot?.turns ?? [] {
            for event in turn.events
            where event.evidence.source.offset >= latest?.event.evidence.source.offset ?? 0 {
                latest = (turn.id, event)
            }
        }
        guard let latest else { return }
        reveal(eventID: latest.event.id, in: latest.turnID)
    }

    func setFilter(_ category: EventFilter) {
        following = false
        filter = category
        timelinePage = 0
    }

    private func enterLiveFollow() {
        following = true
        newEvents = 0
    }
}

// MARK: - Selection

extension Workspace {
    /// Shows a turn chosen in the sidebar, at its remembered or first visible event.
    func showTurn(_ id: String?) {
        following = false
        turnID = id
        showSelectedTurn()
    }

    /// Selects an event the user clicked. Mouse selection does not scroll the timeline.
    func clickEvent(_ event: InspectorEvent) {
        following = false
        eventID = event.id
        loadSelectedEventDetail()
    }

    /// Moves the event selection by `step` visible events, for arrow-key navigation.
    func moveEventSelection(by step: Int) {
        let events = visibleEvents
        guard !events.isEmpty else { return }
        let current = events.firstIndex(where: { $0.id == eventID }) ?? 0
        let next = min(max(current + step, 0), events.count - 1)
        following = false
        eventID = events[next].id
        revealPage()
        relatedNavigation += 1
        loadSelectedEventDetail()
    }

    /// Opens the call or result linked to the selected event.
    func related() {
        guard let id = event?.linkedEvent else { return }
        navigate(toEvent: id)
    }

    /// Opens the request the selected request was compared with.
    func previousRequest() {
        guard let id = event?.metrics?.previousRequest else { return }
        navigate(toEvent: id)
    }

    /// Selects a record the user clicked.
    func clickRecord(_ record: IndexedLogRecord) {
        following = false
        recordID = record.id
        loadSelectedRecordDetail()
    }

    /// Moves the record selection by `step` records, for arrow-key navigation.
    func moveRecordSelection(by step: Int) {
        let records = filteredRecords
        guard !records.isEmpty else { return }
        let current = recordID.flatMap(records.index(ofRecordID:)) ?? 0
        let next = min(max(current + step, 0), records.count - 1)
        following = false
        recordID = records[next].id
        revealRecordPage()
        recordNavigation += 1
        loadSelectedRecordDetail()
    }

    /// Switches to Log Records with the record behind the selected event (or its completion).
    func viewLogRecord(completion: Bool = false) {
        guard let event, let snapshot, let record = snapshot.record(containing: event, completion: completion) else {
            return
        }
        if displayBoundary?.includes(record, generation: snapshot.generation) == false { showHistory() }
        recordLevel = .all
        recordLogger = .all
        browsingMode = .logRecords
        inspector = true
        recordID = record.id
        revealRecordPage()
        recordNavigation += 1
        loadSelectedRecordDetail()
    }

    /// Shows the timeline page that contains the selected event.
    func revealPage() {
        if let index = visibleEvents.firstIndex(where: { $0.id == eventID }) {
            timelinePage = index / pageSize
        } else {
            timelinePage = 0
        }
    }

    /// Shows the record page that contains the selected record.
    func revealRecordPage() {
        if let index = recordID.flatMap(filteredRecords.index(ofRecordID:)) {
            recordPage = index / pageSize
        } else {
            recordPage = 0
        }
    }

    /// Selects the event with `id` wherever it is, clearing filters or the display boundary that
    /// would hide it.
    private func navigate(toEvent id: String) {
        guard let turn = snapshot?.turns.first(where: { $0.events.contains { $0.id == id } }) else { return }
        if let target = turn.events.first(where: { $0.id == id }), !isDisplayed(target) { showHistory() }
        following = false
        filter = .all
        reveal(eventID: id, in: turn.id)
    }

    /// Selects an event in a turn, scrolls it into view, and loads its detail.
    private func reveal(eventID id: String, in turnID: String) {
        remembered[turnID] = id
        self.turnID = turnID
        eventID = id
        revealPage()
        relatedNavigation += 1
        loadSelectedEventDetail()
    }

    /// Selects the current turn's remembered or first visible event and loads it.
    private func showSelectedTurn() {
        if let turn {
            eventID = remembered[turn.id] ?? visibleEvents.first?.id ?? turn.events.first?.id
            revealPage()
        } else {
            eventID = nil
        }
        loadSelectedEventDetail()
    }

    /// After a visibility change, moves the selection off an event that is no longer shown.
    private func keepEventSelectionVisible() {
        guard !visibleEvents.contains(where: { $0.id == eventID }) else { return }
        eventID = visibleEvents.first?.id
        loadSelectedEventDetail()
    }

    private func recordFilterChanged() {
        resetSearchState(dismiss: true)
        following = false
        recordPage = 0
        updateRecords()
        if recordID.flatMap(filteredRecords.index(ofRecordID:)) == nil {
            recordID = filteredRecords.first?.id
            if browsingMode == .logRecords { loadSelectedRecordDetail() }
        }
        revealRecordPage()
        recordNavigation += 1
    }
}

// MARK: - Detail loading

extension Workspace {
    /// Loads the selected event's detail and saves the selection for the next launch.
    private func loadSelectedEventDetail() {
        guard browsingMode == .executions else { return }
        resetDetail()
        guard let event, let snapshot else { return }
        if let turnID { remembered[turnID] = event.id }
        defaults.set(event.id, for: .selectedEvent)
        defaults.set(String(snapshot.inode), for: .selectedInode)
        defaults.set(event.evidence.source.digest, for: .selectedDigest)
        loadDetail(stateKey: event.id) { try LogReader.detail(event, snapshot: snapshot) }
    }

    /// Loads the selected record's detail and saves the selection for the next launch.
    private func loadSelectedRecordDetail() {
        guard browsingMode == .logRecords else { return }
        resetDetail()
        guard let record = selectedRecord, let snapshot else { return }
        defaults.set(record.id, for: .selectedRecord)
        defaults.set(String(snapshot.inode), for: .recordInode)
        defaults.set(record.source.digest, for: .recordDigest)
        loadDetail(stateKey: record.id) { try LogReader.detail(record, snapshot: snapshot) }
    }

    /// Runs `read` off the main actor and publishes its result unless superseded.
    ///
    /// - Parameter stateKey: The ID under which the Structured outline state is kept.
    private func loadDetail(stateKey: String, _ read: @escaping @Sendable () throws -> EventDetail) {
        detailLoading = true
        detailTask = Task {
            do {
                let value = try await Self.runDetached(read)
                guard !Task.isCancelled else { return }
                if structuredStates[stateKey] == nil { structuredStates[stateKey] = StructuredViewState() }
                detail = value
                detailLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                detailError = error.localizedDescription
                detailLoading = false
            }
        }
    }

    /// Runs blocking work on a detached task, cancelling it if the awaiting task is cancelled.
    private nonisolated static func runDetached<Value: Sendable>(
        _ work: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let worker = Task.detached(priority: .userInitiated) { try work() }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyRecord() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recordText, forType: .string)
    }
}

// MARK: - Search

extension Workspace {
    /// Searches the current mode's complete content after a short debounce.
    func runSearch() {
        resetSearchState()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let snapshot = displaySnapshot, !text.isEmpty else { return }
        searching = true
        following = false
        searchGeneration = snapshot.generation
        searchSize = snapshot.size
        if browsingMode == .logRecords {
            let records = filteredRecords
            runSearchTask({ try LogReader.searchRecords(text, snapshot: snapshot, records: records) }) {
                $0.recordSearchResults = $1
            }
        } else {
            runSearchTask({ try LogReader.search(text, snapshot: snapshot) }) { $0.searchResults = $1 }
        }
    }

    func navigate(_ hit: SearchHit) {
        guard searchGeneration == snapshot?.generation else {
            searchError = "The source changed. Search again before opening a result."
            return
        }
        following = false
        filter = .all
        if hit.event.kind == .context { showContext = true }
        searchPresented = false
        reveal(eventID: hit.event.id, in: hit.turnID)
    }

    func navigateRecord(_ hit: RecordSearchHit) {
        guard searchGeneration == snapshot?.generation else {
            searchError = "The source changed. Search again before opening a result."
            return
        }
        following = false
        recordID = hit.record.id
        revealRecordPage()
        recordNavigation += 1
        searchPresented = false
        loadSelectedRecordDetail()
    }

    private func runSearchTask<Results: Sendable>(
        _ search: @escaping @Sendable () throws -> Results, publish: @escaping (Workspace, Results) -> Void
    ) {
        searchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(300))
                let results = try await Self.runDetached(search)
                guard !Task.isCancelled else { return }
                publish(self, results)
                searching = false
            } catch {
                guard !Task.isCancelled else { return }
                searchError = error.localizedDescription
                searching = false
            }
        }
    }
}
