import AppKit
import SwiftUI

#if SWIFT_PACKAGE
    import InspectorCore
#endif

/// The main window: the Executions browser (sidebar, timeline, inspector) or the Log Records browser.
struct InspectorWindow: View {
    @Bindable var workspace: Workspace
    var body: some View {
        Group {
            if workspace.browsingMode == .logRecords {
                HSplitView {
                    LogRecordBrowser(workspace: workspace).frame(minWidth: 370, idealWidth: 520, maxWidth: .infinity)
                    LogRecordInspector(workspace: workspace).frame(minWidth: 380, idealWidth: 700, maxWidth: .infinity)
                }
            } else {
                NavigationSplitView {
                    ExecutionSidebar(workspace: workspace).navigationSplitViewColumnWidth(
                        min: 210, ideal: 250, max: 330)
                } detail: {
                    HSplitView {
                        ExecutionTimeline(workspace: workspace).frame(
                            minWidth: 370, idealWidth: 620, maxWidth: .infinity)
                        if workspace.inspector {
                            EventInspector(workspace: workspace).frame(
                                minWidth: 320, idealWidth: 440, maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    workspace.open()
                } label: {
                    Label("Open Log", systemImage: "folder")
                }.help("Open a read-only log snapshot (⌘O)")
            }
            ToolbarItem(placement: .principal) {
                HStack(spacing: 7) {
                    Image(systemName: "waveform.path").foregroundStyle(.teal)
                    Text("oMLX Inspector").fontWeight(.semibold)
                    Picker("Browse", selection: $workspace.browsingMode) {
                        Text("Executions").tag(BrowsingMode.executions)
                        Text("Log Records").tag(BrowsingMode.logRecords)
                    }.pickerStyle(.segmented).frame(width: 230).help(
                        "Browse reconstructed executions or every original log record")
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if workspace.loading {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { workspace.cancel() }
                }
                Button {
                    if let url = workspace.snapshot?.url { workspace.load(url) }
                } label: {
                    Label("Reindex Log", systemImage: "arrow.clockwise")
                }.disabled(workspace.snapshot == nil || workspace.loading).help("Rebuild the source index (⌘R)")
                Button {
                    workspace.clearDisplay()
                } label: {
                    Label("Clear Display", systemImage: "clear")
                }
                .labelStyle(.titleAndIcon)
                .disabled(workspace.snapshot == nil || workspace.loading || workspace.pendingReplacement != nil)
                .help("Hide current activity and follow new log activity. The log stays untouched (⌘K).")
                Button {
                    workspace.searchPresented = true
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }.help("Search complete content in the current mode (⌘F)").disabled(workspace.snapshot == nil)
                Toggle(isOn: $workspace.monitoring) { Label("Monitor Log", systemImage: "waveform") }.toggleStyle(
                    .button
                ).accessibilityLabel("Monitor Log").help("Read appended records while the application is open")
                Menu {
                    if !workspace.rotatedSources.isEmpty {
                        Section("Previous log files") {
                            ForEach(workspace.rotatedSources, id: \.self) { url in
                                Button(url.lastPathComponent) { workspace.load(url) }
                            }
                        }
                    }
                    Picker("Appearance", selection: $workspace.appearance) {
                        ForEach(Appearance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Show carried assistant context", isOn: $workspace.showContext)
                } label: {
                    Label("View Options", systemImage: "slider.horizontal.3")
                }
                Button {
                    workspace.inspector.toggle()
                } label: {
                    Label("Toggle Inspector", systemImage: "sidebar.right")
                }.help("Show or hide details (⌥⌘I)").disabled(workspace.browsingMode == .logRecords)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar(workspace: workspace) }
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
                        if workspace.pendingReplacement != nil {
                            Text("Your historical view is retained.").font(.caption)
                            Button("Open current log") { workspace.openCurrentGeneration() }
                        }
                        Spacer()
                        Button {
                            workspace.recoveryNotice = nil
                        } label: {
                            Image(systemName: "xmark")
                        }.buttonStyle(.plain).disabled(workspace.pendingReplacement != nil)
                    }.padding(10).background(.bar)
                }
            }
        }
        .task { workspace.restore() }
        .sheet(isPresented: $workspace.searchPresented) {
            if workspace.browsingMode == .logRecords {
                LogRecordSearch(workspace: workspace)
            } else {
                EventSearch(workspace: workspace)
            }
        }
        .alert(
            "Unable to open log",
            isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })
        ) {
            Button("OK") { workspace.error = nil }
        } message: {
            Text(workspace.error ?? "")
        }
    }
}
