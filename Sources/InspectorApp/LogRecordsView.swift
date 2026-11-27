import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import InspectorCore
#endif

struct LogRecordBrowser: View {
    @Bindable var workspace: Workspace
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("LOG RECORDS").font(.system(size: 10, weight: .bold)).tracking(1.5).foregroundStyle(.secondary)
                HStack {
                    Text(workspace.snapshot?.url.lastPathComponent ?? "No log open").font(.title2.weight(.semibold))
                    Spacer()
                    Text("\(workspace.filteredRecords.count.formatted()) records").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Picker("Level", selection: $workspace.recordLevel) {
                        ForEach(["All levels", "TRACE", "DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"], id: \.self) { Text($0) }
                    }
                    Picker("Logger", selection: $workspace.recordLogger) {
                        Text("All loggers").tag("All loggers")
                        ForEach(workspace.recordLoggers, id: \.self) { Text($0).tag($0) }
                    }
                }.controlSize(.small)
                HStack {
                    if workspace.following {
                        Label("Following", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.teal)
                        Spacer()
                        Button("Pause") { workspace.following = false }
                    } else {
                        Button(workspace.newEvents > 0 ? "Return to Live · \(workspace.newEvents) new" : "Return to Live") {
                            workspace.monitoring = true; workspace.followLatest()
                        }
                        Spacer()
                    }
                }.font(.caption).controlSize(.small)
                if workspace.recordPageCount > 1 {
                    HStack {
                        Button("Previous records") { workspace.following = false; workspace.recordPage -= 1 }.disabled(workspace.recordPage == 0)
                        Spacer()
                        Text("Page \(workspace.recordPage + 1) of \(workspace.recordPageCount)").font(.caption)
                        Spacer()
                        Button("Next records") { workspace.following = false; workspace.recordPage += 1 }.disabled(workspace.recordPage + 1 >= workspace.recordPageCount)
                    }.controlSize(.small)
                }
            }.padding(18)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    // Fixed page and eager rows preserve stationary click selection.
                    VStack(spacing: 3) {
                        ForEach(workspace.pagedRecords) { record in
                            Button {
                                focused = true; workspace.following = false
                                workspace.recordID = record.id; workspace.selectRecord()
                            } label: {
                                LogRecordRow(record: record, selected: record.id == workspace.recordID)
                            }.buttonStyle(.plain).id(record.id)
                                .accessibilityAddTraits(record.id == workspace.recordID ? .isSelected : [])
                        }
                    }.padding(10)
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting || phase == .tracking { workspace.following = false }
                }
                .focusable().focusEffectDisabled().focused($focused)
                .onMoveCommand { direction in
                    guard direction == .up || direction == .down else { return }
                    let records = workspace.filteredRecords
                    guard !records.isEmpty else { return }
                    let index = records.firstIndex { $0.id == workspace.recordID } ?? 0
                    let next = min(max(index + (direction == .down ? 1 : -1), 0), records.count - 1)
                    workspace.following = false; workspace.recordID = records[next].id
                    workspace.revealRecordPage(); workspace.recordNavigation += 1; workspace.selectRecord()
                }
                .task(id: workspace.recordNavigation) {
                    // Wait for the new page/mode to lay out before an explicit reveal.
                    // Ordinary click selection never changes this task's identity.
                    await Task.yield()
                    if let id = workspace.recordID { proxy.scrollTo(id, anchor: workspace.following ? .bottom : .center) }
                }
                .overlay {
                    if workspace.filteredRecords.isEmpty {
                        if workspace.snapshot == nil {
                            ContentUnavailableView {
                                Label("Open an oMLX log", systemImage: "doc.text.magnifyingglass")
                            } actions: { Button("Open Log…") { workspace.open() } }
                        } else {
                            ContentUnavailableView("No matching records", systemImage: "line.3.horizontal.decrease",
                                                   description: Text(workspace.displayBoundary == nil ? "Choose another level or logger." : "Waiting for new activity. Show History restores earlier records."))
                        }
                    }
                }
            }.id(workspace.recordPage)
        }.background(Color(nsColor: .textBackgroundColor))
    }
}

struct LogRecordRow: View {
    @Environment(\.colorScheme) private var scheme
    let record: IndexedLogRecord
    let selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(record.timestamp.isEmpty ? "Unframed / partial" : record.timestamp).monospacedDigit()
                Spacer(minLength: 0)
                Text(record.level).fontWeight(.semibold).foregroundStyle(["ERROR", "CRITICAL", "WARNING"].contains(record.level) ? Color.orange : Color.secondary)
            }.font(.system(size: 10, design: .monospaced))
            Text(record.summary).font(.system(size: 12)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Text(record.logger).lineLimit(1)
                Spacer(minLength: 4)
                Text("L\(record.source.line)").monospacedDigit()
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            if let id = record.requestID { Text(id).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1) }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.blue.opacity(scheme == .dark ? 0.30 : 0.18) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.blue.opacity(0.55) : .clear, lineWidth: 1) }
            .contentShape(Rectangle())
    }
}

struct LogRecordInspector: View {
    @Bindable var workspace: Workspace
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let record = workspace.selectedRecord {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("RECORD INSPECTOR").font(.system(size: 10, weight: .bold)).tracking(1.5).foregroundStyle(.secondary)
                        Spacer()
                        Button { workspace.copyRecord() } label: { Label("Copy", systemImage: "doc.on.doc") }
                            .controlSize(.small).disabled(workspace.detail == nil).help("Copy the complete representation")
                    }
                    Text(record.timestamp.isEmpty ? "Unframed / partial record" : record.timestamp).font(.title3.weight(.semibold)).textSelection(.enabled)
                    Text("\(record.level) · \(record.logger)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Lines \(record.source.line)–\(record.source.endLine) · \(record.source.length.formatted()) bytes").font(.caption).foregroundStyle(.secondary)
                    if record.context != "-" { Text("Context: \(record.context)").font(.caption).textSelection(.enabled) }
                    if let id = record.requestID { Text(id).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                    Button("Return to executions →") { workspace.browsingMode = "Executions" }.buttonStyle(.link).font(.caption)
                    Picker("Record representation", selection: $workspace.recordMode) {
                        Text("Structured").tag("Structured"); Text("Source").tag("Source")
                    }.pickerStyle(.segmented).labelsHidden()
                    Text(workspace.recordMode == "Source" ? "The exact original log record" : "Complete request fields, or record metadata and message")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(18)
                Divider()
                if workspace.detailLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let error = workspace.detailError {
                    ContentUnavailableView("Source unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if workspace.recordMode == "Structured", let tree = workspace.detail?.tree, let state = workspace.structuredStates[record.id] {
                    StructuredInspector(root: tree, identity: record.id, state: state).id(record.id)
                } else {
                    NativeText(text: String(workspace.recordText.prefix(workspace.visibleCharacters)), identity: "\(record.id)-\(workspace.recordMode)")
                    if workspace.recordText.count > workspace.visibleCharacters {
                        HStack {
                            Text("More content is available.").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Load more") { workspace.visibleCharacters += 80000 }.controlSize(.small)
                        }.padding(10)
                    }
                }
            } else {
                ContentUnavailableView("Inspect a log record", systemImage: "cursorarrow.click", description: Text("Select a record to explore its fields and original source."))
            }
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}

struct LogRecordSearch: View {
    @Bindable var workspace: Workspace
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Search log records").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { workspace.searchPresented = false }.keyboardShortcut(.cancelAction)
            }
            TextField("Record text, request IDs, messages, URLs…", text: $workspace.query)
                .textFieldStyle(.roundedBorder).focused($focused).onSubmit { workspace.runSearch() }
                .onChange(of: workspace.query) { workspace.runSearch() }
            HStack {
                Text("Searches complete source records within the current level, logger, and display filters.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if workspace.searching { ProgressView().controlSize(.small) }
                Button("Search again") { workspace.runSearch() }.controlSize(.small).disabled(workspace.query.isEmpty)
            }
            if let error = workspace.searchError { Text(error).foregroundStyle(.orange).font(.caption) }
            if let results = workspace.recordSearchResults {
                HStack {
                    Text(results.limited ? "First \(results.hits.count) matches · refine your search for more" : "\(results.hits.count) matching records").font(.caption)
                    Spacer()
                    if workspace.searchSize != workspace.snapshot?.size { Text("New log content available · search again").font(.caption).foregroundStyle(.secondary) }
                }
                if results.hits.isEmpty { ContentUnavailableView.search(text: workspace.query) }
                else {
                    List(results.hits) { hit in
                        Button { workspace.navigateRecord(hit) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text("\(hit.record.level) · \(hit.record.logger)").fontWeight(.semibold)
                                    Spacer()
                                    Text(hit.record.timestamp).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(hit.preview).font(.system(size: 11, design: .monospaced)).lineLimit(3)
                            }.padding(.vertical, 5).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }.listStyle(.inset)
                }
            } else {
                ContentUnavailableView("Find a log record", systemImage: "magnifyingglass", description: Text("Search every record, including scheduler, cache, and model-loading activity."))
            }
        }.padding(22).frame(width: 760, height: 560)
            .onAppear { focused = true; if !workspace.query.isEmpty { workspace.runSearch() } }
    }
}
