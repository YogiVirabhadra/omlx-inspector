import AppKit
import SwiftUI

#if SWIFT_PACKAGE
    import InspectorCore
#endif

/// The paged, filterable list of every framed log record.
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
                    Text("\(workspace.filteredRecords.count.formatted()) records").font(.caption).foregroundStyle(
                        .secondary)
                }
                HStack {
                    Picker("Level", selection: $workspace.recordLevel) {
                        ForEach(RecordLevel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Logger", selection: $workspace.recordLogger) {
                        Text("All loggers").tag(LoggerFilter.all)
                        ForEach(workspace.recordLoggers, id: \.self) { Text($0).tag(LoggerFilter.named($0)) }
                    }
                }.controlSize(.small)
                HStack {
                    if workspace.following {
                        Label("Following", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.teal)
                        Spacer()
                        Button("Pause") { workspace.following = false }
                    } else {
                        Button(
                            workspace.newEvents > 0 ? "Return to Live · \(workspace.newEvents) new" : "Return to Live"
                        ) {
                            workspace.monitoring = true
                            workspace.followLatest()
                        }
                        Spacer()
                    }
                }.font(.caption).controlSize(.small)
                if workspace.recordPageCount > 1 {
                    HStack {
                        Button("Previous records") {
                            workspace.following = false
                            workspace.recordPage -= 1
                        }.disabled(workspace.recordPage == 0)
                        Spacer()
                        Text("Page \(workspace.recordPage + 1) of \(workspace.recordPageCount)").font(.caption)
                        Spacer()
                        Button("Next records") {
                            workspace.following = false
                            workspace.recordPage += 1
                        }.disabled(workspace.recordPage + 1 >= workspace.recordPageCount)
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
                                focused = true
                                workspace.clickRecord(record)
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
                    workspace.moveRecordSelection(by: direction == .down ? 1 : -1)
                }
                .task(id: workspace.recordNavigation) {
                    // Wait for the new page/mode to lay out before an explicit reveal.
                    // Ordinary click selection never changes this task's identity.
                    await Task.yield()
                    if let id = workspace.recordID {
                        proxy.scrollTo(id, anchor: workspace.following ? .bottom : .center)
                    }
                }
                .overlay {
                    if workspace.filteredRecords.isEmpty {
                        if workspace.snapshot == nil {
                            ContentUnavailableView {
                                Label("Open an oMLX log", systemImage: "doc.text.magnifyingglass")
                            } actions: {
                                Button("Open Log…") { workspace.open() }
                            }
                        } else {
                            ContentUnavailableView(
                                "No matching records", systemImage: "line.3.horizontal.decrease",
                                description: Text(
                                    workspace.displayBoundary == nil
                                        ? "Choose another level or logger."
                                        : "Waiting for new activity. Show History restores earlier records."))
                        }
                    }
                }
            }.id(workspace.recordPage)
        }.background(Color(nsColor: .textBackgroundColor))
    }
}

/// One record in the Log Records list.
struct LogRecordRow: View {
    @Environment(\.colorScheme) private var scheme
    let record: IndexedLogRecord
    let selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(record.timestamp.isEmpty ? "Unframed / partial" : record.timestamp).monospacedDigit()
                Spacer(minLength: 0)
                Text(record.level).fontWeight(.semibold).foregroundStyle(
                    record.isProblem ? Color.orange : Color.secondary)
            }.font(.system(size: 10, design: .monospaced))
            Text(record.summary).font(.system(size: 12)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Text(record.logger).lineLimit(1)
                Spacer(minLength: 4)
                Text("L\(record.source.line)").monospacedDigit()
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            if let id = record.requestID {
                Text(id).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Color.blue.opacity(scheme == .dark ? 0.30 : 0.18) : Color.primary.opacity(0.025),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(
                    selected ? Color.blue.opacity(0.55) : .clear, lineWidth: 1)
            }
            .contentShape(Rectangle())
    }
}
