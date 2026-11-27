import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import InspectorCore
#endif

@main struct InspectorApp: App {
    @State private var workspace = Workspace()
    var body: some Scene {
        WindowGroup("oMLX Inspector") {
            InspectorWindow(workspace: workspace)
                .frame(minWidth: 940, minHeight: 620)
                .preferredColorScheme(workspace.appearance == "Dark" ? .dark : workspace.appearance == "Light" ? .light : nil)
                .onOpenURL { workspace.load($0) }
        }
        .defaultSize(width: 1360, height: 850)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Log…") { workspace.open() }.keyboardShortcut("o")
                Button("Reindex Log") { if let url = workspace.snapshot?.url { workspace.load(url) } }.keyboardShortcut("r").disabled(workspace.snapshot == nil || workspace.loading)
            }
            CommandGroup(after: .textEditing) {
                Button("Clear Display") { workspace.clearDisplay() }.keyboardShortcut("k")
                    .disabled(workspace.snapshot == nil || workspace.loading || workspace.pendingReplacement != nil)
                Button("Search…") { workspace.searchPresented = true }.keyboardShortcut("f")
                Button("Return to Live") { workspace.monitoring = true; workspace.followLatest() }.keyboardShortcut("l", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Toggle("Show Inspector", isOn: $workspace.inspector).keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
    }
}

struct InspectorWindow: View {
    @Bindable var workspace: Workspace
    @FocusState private var timelineFocused: Bool
    var body: some View {
        Group {
            if workspace.browsingMode == "Log Records" {
                HSplitView {
                    LogRecordBrowser(workspace: workspace).frame(minWidth: 370, idealWidth: 520, maxWidth: .infinity)
                    LogRecordInspector(workspace: workspace).frame(minWidth: 380, idealWidth: 700, maxWidth: .infinity)
                }
            } else {
                NavigationSplitView {
                    sidebar.navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 330)
                } detail: {
                    HSplitView {
                        timeline.frame(minWidth: 370, idealWidth: 620, maxWidth: .infinity)
                        if workspace.inspector { inspector.frame(minWidth: 320, idealWidth: 440, maxWidth: .infinity) }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { workspace.open() } label: { Label("Open Log", systemImage: "folder") }.help("Open a read-only log snapshot (⌘O)")
            }
            ToolbarItem(placement: .principal) {
                HStack(spacing: 7) {
                    Image(systemName: "waveform.path").foregroundStyle(.teal)
                    Text("oMLX Inspector").fontWeight(.semibold)
                    Picker("Browse", selection: $workspace.browsingMode) {
                        Text("Executions").tag("Executions")
                        Text("Log Records").tag("Log Records")
                    }.pickerStyle(.segmented).frame(width: 230).help("Browse reconstructed executions or every original log record")
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if workspace.loading { ProgressView().controlSize(.small); Button("Cancel") { workspace.cancel() } }
                Button { if let url = workspace.snapshot?.url { workspace.load(url) } } label: { Label("Reindex Log", systemImage: "arrow.clockwise") }.disabled(workspace.snapshot == nil || workspace.loading).help("Rebuild the source index (⌘R)")
                Button { workspace.clearDisplay() } label: { Label("Clear Display", systemImage: "clear") }
                    .labelStyle(.titleAndIcon)
                    .disabled(workspace.snapshot == nil || workspace.loading || workspace.pendingReplacement != nil)
                    .help("Hide current activity and follow new log activity. The log stays untouched (⌘K).")
                Button { workspace.searchPresented = true } label: { Label("Search", systemImage: "magnifyingglass") }.help("Search complete content in the current mode (⌘F)").disabled(workspace.snapshot == nil)
                Toggle(isOn: $workspace.monitoring) { Label("Monitor Log", systemImage: "waveform") }.toggleStyle(.button).accessibilityLabel("Monitor Log").help("Read appended records while the application is open")
                Menu {
                    if !workspace.rotatedSources.isEmpty {
                        Section("Previous log files") {
                            ForEach(workspace.rotatedSources, id: \.self) { url in Button(url.lastPathComponent) { workspace.load(url) } }
                        }
                    }
                    Picker("Appearance", selection: $workspace.appearance) { ForEach(["System", "Light", "Dark"], id: \.self) { Text($0) } }
                    Toggle("Show carried assistant context", isOn: $workspace.showContext)
                } label: { Label("View Options", systemImage: "slider.horizontal.3") }
                Button { workspace.inspector.toggle() } label: { Label("Toggle Inspector", systemImage: "sidebar.right") }.help("Show or hide details (⌥⌘I)").disabled(workspace.browsingMode == "Log Records")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { status }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if workspace.displayBoundary != nil {
                    HStack {
                        Label("Showing activity since Clear Display", systemImage: "sparkle").font(.caption)
                        Spacer()
                        Button("Show History") { workspace.showHistory() }.controlSize(.small)
                    }.padding(.horizontal, 16).padding(.vertical, 8).background(.bar)
                }
                if let notice = workspace.recoveryNotice {
                    HStack {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(notice).font(.caption)
                        if workspace.pendingReplacement != nil { Text("Your historical view is retained.").font(.caption); Button("Open current log") { workspace.openCurrentGeneration() } }
                        Spacer()
                        Button { workspace.recoveryNotice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).disabled(workspace.pendingReplacement != nil)
                    }.padding(10).background(.bar)
                }
            }
        }
        .task { workspace.restore() }
        .sheet(isPresented: $workspace.searchPresented) {
            if workspace.browsingMode == "Log Records" { LogRecordSearch(workspace: workspace) }
            else { EventSearch(workspace: workspace) }
        }
        .alert("Unable to open log", isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) { Button("OK") { workspace.error = nil } } message: { Text(workspace.error ?? "") }
        .onChange(of: workspace.turnID) { workspace.selectTurn() }
        .onChange(of: workspace.eventID) { workspace.selectEvent() }
        .onChange(of: workspace.showContext) { if !workspace.visibleEvents.contains(where: { $0.id == workspace.eventID }) { workspace.eventID = workspace.visibleEvents.first?.id } }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("EXECUTIONS").font(.system(size: 10, weight: .bold)).tracking(1.5).foregroundStyle(.secondary)
                Text(workspace.snapshot?.url.lastPathComponent ?? "No log open").font(.title3.weight(.semibold)).lineLimit(1)
                if let s = workspace.displaySnapshot {
                    Text("\(s.requestCount) requests · \(s.callCount) tool calls").font(.caption).foregroundStyle(.secondary)
                } else { Text("Explore what your agent did.").font(.caption).foregroundStyle(.secondary) }
            }.padding(18)
            Divider()
            if let s = workspace.displaySnapshot {
                let groups = Dictionary(grouping: s.turns, by: \.group)
                List(selection: Binding(get: { workspace.turnID }, set: { workspace.following = false; workspace.turnID = $0 })) {
                    ForEach(groups.keys.sorted(), id: \.self) { group in
                        Section(group == 0 ? "Diagnostics" : "Conversation \(group) · inferred") {
                            ForEach(groups[group] ?? []) { turn in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(turn.title).font(.system(size: 12, weight: .medium)).lineLimit(3)
                                    HStack(spacing: 9) {
                                        Label("\(turn.requests)", systemImage: "cpu")
                                        Label("\(turn.calls)", systemImage: "wrench.and.screwdriver")
                                        Spacer(minLength: 0)
                                        Text(String(turn.observed.dropFirst(11).prefix(5)))
                                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                                }.padding(.vertical, 5).tag(turn.id)
                            }
                        }
                    }
                }.listStyle(.sidebar)
            } else { Spacer() }
        }
    }
    private var timeline: some View {
        VStack(spacing: 0) {
            if let turn = workspace.turn {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(turn.group == 0 ? "DIAGNOSTICS" : "USER TURN").font(.system(size: 10, weight: .bold)).tracking(1.5).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(turn.requests) inference cycles   ·   \(turn.calls) tool calls").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(turn.title).font(.system(size: 21, weight: .semibold)).lineLimit(3).textSelection(.enabled)
                    if turn.group == 0 {
                        Text("Unattributed source diagnostics").font(.system(size: 10)).foregroundStyle(.secondary)
                    } else {
                        let metrics = turn.metrics
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 24) { turnMetrics(metrics, inferenceCount: turn.requests) }
                            VStack(alignment: .leading, spacing: 8) { turnMetrics(metrics, inferenceCount: turn.requests) }
                        }
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                HStack(spacing: 12) {
                    Picker("Show", selection: Binding(get: { workspace.filter }, set: { workspace.setFilter($0) })) { ForEach(EventFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(maxWidth: 210)
                    Text("\(workspace.visibleEvents.count) events").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if workspace.following {
                        Label("Following", systemImage: "dot.radiowaves.left.and.right").font(.caption).foregroundStyle(.teal)
                        Button("Pause") { workspace.following = false }
                    } else {
                        Button(workspace.newEvents > 0 ? "Return to Live · \(workspace.newEvents) new" : "Return to Live") { workspace.monitoring = true; workspace.followLatest() }
                            .help("Follow the newest event. Scrolling or selecting a card pauses following (⇧⌘L).")
                    }
                }.controlSize(.small).padding(.horizontal, 16).padding(.vertical, 9)
                if workspace.pageCount > 1 {
                    HStack {
                        Button("Previous events") { workspace.following = false; workspace.timelinePage = max(0, workspace.timelinePage - 1) }.disabled(workspace.timelinePage == 0)
                        Spacer(); Text("Page \(workspace.timelinePage + 1) of \(workspace.pageCount)").font(.caption); Spacer()
                        Button("Next events") { workspace.following = false; workspace.timelinePage = min(workspace.pageCount - 1, workspace.timelinePage + 1) }.disabled(workspace.timelinePage + 1 >= workspace.pageCount)
                    }.controlSize(.small).padding(.horizontal, 16).padding(.bottom, 8)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        // Eager layout keeps the document's measured heights stable during
                        // selection; List's estimated offscreen row heights can shift it.
                        VStack(spacing: 0) {
                            ForEach(workspace.visibleCycles) { cycle in
                                if let number = cycle.number {
                                    HStack(spacing: 8) {
                                        Image(systemName: number == 1 ? "arrow.turn.down.right" : "arrow.down")
                                        Text("INFERENCE \(number)").tracking(1)
                                        Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1)
                                        Label(cycle.completion?.label ?? "Finish unavailable", systemImage: cycle.completion == nil ? "questionmark.circle" : "link")
                                            .font(.system(size: 10, weight: .medium)).lineLimit(1)
                                            .foregroundStyle(cycle.completion?.finishReason == "length" ? Color.orange : Color.secondary)
                                            .help(cycle.completion.map { "finish_reason=\($0.finishReason ?? "unavailable") · reported by oMLX. " + $0.association } ?? "No reliably associated server completion record. Scheduler stop is not a server finish reason.")
                                    }.font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                                        .padding(.top, 12).padding(.bottom, 6)
                                }
                                ForEach(cycle.events) { event in
                                    Button { timelineFocused = true; workspace.clickEvent(event) } label: {
                                        EventRow(event: event, selected: workspace.eventID == event.id,
                                                 inCycle: cycle.number != nil,
                                                 lastInCycle: cycle.events.last?.id == event.id)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .id(event.id)
                                    .accessibilityAddTraits(workspace.eventID == event.id ? .isSelected : [])
                                }
                            }
                        }.padding(.horizontal, 14).padding(.bottom, 12)
                    }
                    .onScrollPhaseChange { _, phase in
                        if phase == .interacting || phase == .tracking { workspace.following = false }
                    }
                    .overlay {
                        if workspace.visibleEvents.isEmpty { ContentUnavailableView("No matching events", systemImage: "line.3.horizontal.decrease", description: Text("Choose another category to see this turn's events.")) }
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .focused($timelineFocused)
                    .onMoveCommand { direction in
                        guard direction == .up || direction == .down else { return }
                        let events = workspace.visibleEvents
                        guard !events.isEmpty else { return }
                        let current = events.firstIndex(where: { $0.id == workspace.eventID }) ?? 0
                        let next = min(max(current + (direction == .down ? 1 : -1), 0), events.count - 1)
                        workspace.following = false; workspace.eventID = events[next].id
                        workspace.revealPage(); workspace.relatedNavigation += 1
                    }
                    // Mouse selection never requests a reveal. Keyboard navigation and
                    // explicit “View call / result” navigation still bring targets into view.
                    .onChange(of: workspace.relatedNavigation) { if let id = workspace.eventID { proxy.scrollTo(id, anchor: workspace.following ? .bottom : nil) } }
                    .onAppear { if let id = workspace.eventID { proxy.scrollTo(id) } }
                }.id("\(turn.id)-\(workspace.timelinePage)")
            } else if workspace.displayBoundary != nil {
                ContentUnavailableView {
                    Label("Display cleared", systemImage: "sparkle")
                } description: {
                    Text(workspace.monitoring ? "Waiting for new log activity. Your log and earlier history are preserved." : "Monitoring is paused. Resume it to see new activity.")
                } actions: {
                    if !workspace.monitoring { Button("Resume Monitoring") { workspace.monitoring = true; workspace.followLatest() } }
                    Button("Show History") { workspace.showHistory() }
                }
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "waveform.path").font(.system(size: 52, weight: .ultraLight)).foregroundStyle(.teal)
                    Text("Follow the evidence.").font(.system(size: 28, weight: .semibold))
                    Text("Turn verbose inference logs into a readable execution history.\nInspect requests, model output, and tool interactions.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).lineSpacing(4)
                    Button("Open an oMLX Log…") { workspace.open() }.buttonStyle(.borderedProminent).controlSize(.large).tint(.teal)
                    Text("LOCAL  ·  READ-ONLY  ·  PRIVATE").font(.system(size: 10, weight: .medium)).tracking(1.2).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(Color(nsColor: .textBackgroundColor))
    }
    @ViewBuilder private func turnMetrics(_ metrics: TurnMetrics, inferenceCount: Int) -> some View {
        Label {
            HStack(spacing: 6) {
                Text(metrics.contextLabel).foregroundStyle(.secondary)
                Text(metrics.contextValue).fontWeight(.semibold)
            }
        } icon: { Image(systemName: "chart.bar.xaxis").foregroundStyle(.secondary) }
        .font(.system(size: 12)).fixedSize().help(metrics.contextHelp)
        Label {
            HStack(spacing: 6) {
                Text(metrics.durationLabel).foregroundStyle(.secondary)
                Text(metrics.durationValue).fontWeight(.semibold)
            }
        } icon: { Image(systemName: "clock").foregroundStyle(.secondary) }
        .font(.system(size: 12)).monospacedDigit().fixedSize().help(metrics.durationHelp)
        Label {
            HStack(spacing: 6) {
                Text("Inferences").foregroundStyle(.secondary)
                Text(inferenceCount.formatted()).fontWeight(.semibold)
            }
        } icon: { Image(systemName: "cpu").foregroundStyle(.secondary) }
        .font(.system(size: 12)).monospacedDigit().fixedSize()
        .help("Total inference requests observed in this turn, across all timeline pages and filters.")
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let e = workspace.event {
                let displayedSource = workspace.mode == "Source" && workspace.completionSource ? e.completion?.source ?? e.evidence.source : e.evidence.source
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("INSPECTOR").font(.system(size: 10, weight: .bold)).tracking(1.5).foregroundStyle(.secondary)
                        Spacer()
                        Button { workspace.copy() } label: { Label("Copy", systemImage: "doc.on.doc") }.controlSize(.small).disabled(workspace.detail == nil).help("Copy the complete selected representation, including text not yet displayed")
                    }
                    Label(e.title, systemImage: e.kind.symbol).font(.title3.weight(.semibold)).textSelection(.enabled)
                    Text(e.note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let id = e.toolID ?? e.requestID { Text(id).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary) }
                    HStack {
                        Text("Lines \(displayedSource.line)–\(displayedSource.endLine)")
                        Spacer()
                        if e.metrics?.previousRequest != nil {
                            Button(e.metrics?.possibleReset == true ? "Comparison candidate →" : "Previous request →") { workspace.previousRequest() }.buttonStyle(.link)
                        }
                        if e.linkedEvent != nil { Button(e.kind == .call ? "View result →" : "View call →") { workspace.related() }.buttonStyle(.link) }
                    }.font(.caption)
                    Button("View log record →") { workspace.viewLogRecord(completion: workspace.mode == "Source" && workspace.completionSource) }
                        .buttonStyle(.link).font(.caption).help("Open this exact source record in Log Records")
                    Picker("Representation", selection: $workspace.mode) {
                        Text("Readable").tag("Readable"); Text("Structured").tag("Structured"); Text("Source").tag("Source")
                    }.pickerStyle(.segmented).labelsHidden()
                    if workspace.mode == "Source", e.completion != nil {
                        Picker("Source record", selection: $workspace.completionSource) {
                            Text("Original event").tag(false)
                            Text("Completion INFO").tag(true)
                        }.pickerStyle(.segmented).labelsHidden()
                    }
                    Text(workspace.mode == "Readable" ? "Understand · a concise interpretation" : workspace.mode == "Structured" ? "Investigate · explore the parsed fields" : "Verify · the original log record")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(18)
                Divider()
                if workspace.detailLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let error = workspace.detailError {
                    ContentUnavailableView("Source unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if workspace.mode == "Structured", let tree = workspace.detail?.tree, let state = workspace.structuredStates[e.id] {
                    StructuredInspector(root: tree, identity: e.id, state: state).id(e.id)
                } else {
                    NativeText(text: String(workspace.text.prefix(workspace.visibleCharacters)), identity: "\(e.id)-\(workspace.mode)-\(workspace.mode == "Source" && workspace.completionSource)")
                    if workspace.text.count > workspace.visibleCharacters {
                        HStack {
                            Text("More content is available.").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Load more") { workspace.visibleCharacters += 80000 }.controlSize(.small)
                        }.padding(10)
                    }
                }
            } else {
                ContentUnavailableView("Inspect an event", systemImage: "cursorarrow.click", description: Text("Select a request, output, or tool event to see the evidence behind it."))
            }
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    private var status: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield").foregroundStyle(.teal)
            Text(workspace.monitoring ? "Read-only · Monitoring" : "Read-only · Monitoring paused").fontWeight(.medium)
            if let s = workspace.snapshot {
                Text("· \(ByteCountFormatter.string(fromByteCount: Int64(s.size), countStyle: .file)) · \(s.recordCount.formatted()) records").foregroundStyle(.secondary)
                if s.hasPartialRecord { Text("· Partial record pending").foregroundStyle(.orange) }
                if workspace.monitorStatus.hasPrefix("Waiting") { Text(workspace.monitorStatus).foregroundStyle(.orange).lineLimit(1).help(workspace.monitorStatus) }
                Spacer()
                if !s.warnings.isEmpty { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(s.warnings.joined(separator: "\n")) }
                Text(s.url.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).help(s.url.path)
            } else { Spacer() }
        }.font(.system(size: 10)).padding(.horizontal, 14).padding(.vertical, 9).background(.bar)
    }
}

struct EventRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let event: InspectorEvent
    let selected: Bool
    let inCycle: Bool
    let lastInCycle: Bool
    private var color: Color { switch event.kind {
    case .user: .blue; case .request: .purple; case .output: .teal; case .call: .orange; case .result: .teal; case .context: .gray; case .diagnostic: .orange
    } }
    private var inset: CGFloat { !inCycle || event.kind == .request ? 0 : event.kind == .result ? 28 : 14 }
    var body: some View {
        HStack(spacing: 0) {
            if inCycle {
                GeometryReader { geometry in
                    Path { path in
                        let x: CGFloat = 9
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: lastInCycle ? 26 : geometry.size.height))
                        path.move(to: CGPoint(x: x, y: 26))
                        path.addLine(to: CGPoint(x: geometry.size.width - 2, y: 26))
                    }.stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    Circle().fill(event.kind == .request ? Color.purple : Color.secondary.opacity(0.45))
                        .frame(width: event.kind == .request ? 7 : 5, height: event.kind == .request ? 7 : 5)
                        .position(x: 9, y: 26)
                }.frame(width: 23 + inset).accessibilityHidden(true)
            }
            card.padding(.vertical, 3)
        }
    }
    private var card: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.kind.symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(selected ? .white : color)
                .frame(width: 30, height: 30).background(color.opacity(selected ? 0.8 : 0.09), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.continuation?.reason ?? event.title).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 8)
                    Text(String(event.timestamp.dropFirst(11).prefix(8))).font(.system(size: 10, design: .monospaced)).opacity(0.65)
                }
                if let continuation = event.continuation {
                    Text(continuation.messageDescription).font(.system(size: 11, weight: .medium)).opacity(0.85)
                }
                Text(event.compactSummary.isEmpty ? "No text content" : event.compactSummary).font(.system(size: 11, design: event.kind == .call ? .monospaced : .default)).lineLimit(2).opacity(0.78)
                HStack(spacing: 6) {
                    Text(event.kind.rawValue.uppercased()).font(.system(size: 8, weight: .bold)).tracking(0.8).opacity(0.6)
                    if event.kind == .call { Text(event.linkedEvent == nil ? "· Result not observed" : "· Reported result available").font(.system(size: 9)).opacity(0.7) }
                    Spacer()
                }
            }
        }.padding(12)
            .background(selected ? Color.blue.opacity(colorScheme == .dark ? 0.30 : 0.18) : Color.primary.opacity(event.kind == .request ? 0.055 : 0.025), in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Color.blue.opacity(0.55) : Color.clear, lineWidth: 1) }
    }
}

struct NativeText: NSViewRepresentable {
    let text: String
    let identity: String
    final class Coordinator { var identity = ""; var text = "" }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = true
        let view = NSTextView(); view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular); view.textContainerInset = NSSize(width: 14, height: 16)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false; view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true; view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.usesFindBar = true; view.isAutomaticLinkDetectionEnabled = false
        view.setAccessibilityLabel("Event evidence text")
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if context.coordinator.text != text || context.coordinator.identity != identity {
            let reset = context.coordinator.identity != identity
            view.string = text; view.textColor = .textColor; view.backgroundColor = .textBackgroundColor
            if reset { view.scrollToBeginningOfDocument(nil) }
            context.coordinator.text = text; context.coordinator.identity = identity
        }
    }
}
