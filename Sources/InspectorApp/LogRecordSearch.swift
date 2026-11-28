import AppKit
import SwiftUI

#if SWIFT_PACKAGE
    import InspectorCore
#endif

/// The search sheet for Log Records mode.
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
                Text("Searches complete source records within the current level, logger, and display filters.").font(
                    .caption
                ).foregroundStyle(.secondary)
                Spacer()
                if workspace.searching { ProgressView().controlSize(.small) }
                Button("Search again") { workspace.runSearch() }.controlSize(.small).disabled(workspace.query.isEmpty)
            }
            if let error = workspace.searchError { Text(error).foregroundStyle(.orange).font(.caption) }
            if let results = workspace.recordSearchResults {
                HStack {
                    Text(
                        results.limited
                            ? "First \(results.hits.count) matches · refine your search for more"
                            : "\(results.hits.count) matching records"
                    ).font(.caption)
                    Spacer()
                    if workspace.searchSize != workspace.snapshot?.size {
                        Text("New log content available · search again").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if results.hits.isEmpty {
                    ContentUnavailableView.search(text: workspace.query)
                } else {
                    List(results.hits) { hit in
                        Button {
                            workspace.navigateRecord(hit)
                        } label: {
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
                ContentUnavailableView(
                    "Find a log record", systemImage: "magnifyingglass",
                    description: Text("Search every record, including scheduler, cache, and model-loading activity."))
            }
        }.padding(22).frame(width: 760, height: 560)
            .onAppear {
                focused = true
                if !workspace.query.isEmpty { workspace.runSearch() }
            }
    }
}
