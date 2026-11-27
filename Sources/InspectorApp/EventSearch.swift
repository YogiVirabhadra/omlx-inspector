import SwiftUI
#if SWIFT_PACKAGE
import InspectorCore
#endif

struct EventSearch: View {
    @Bindable var workspace: Workspace
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Search events").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { workspace.searchPresented = false }.keyboardShortcut(.cancelAction)
            }
            TextField("Messages, tools, results, identifiers, URLs…", text: $workspace.query)
                .textFieldStyle(.roundedBorder).focused($focused).onSubmit { workspace.runSearch() }
                .onChange(of: workspace.query) { workspace.runSearch() }
            HStack {
                Text(workspace.displayBoundary == nil ? "Searches complete event content across all turns and categories." : "Searches activity since Clear Display. Show History restores earlier search results.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if workspace.searching { ProgressView().controlSize(.small) }
                Button("Search again") { workspace.runSearch() }.controlSize(.small).disabled(workspace.query.isEmpty)
            }
            if let error = workspace.searchError { Text(error).foregroundStyle(.orange).font(.caption) }
            if let results = workspace.searchResults {
                HStack {
                    Text(results.limited ? "First \(results.hits.count) matches · refine your search for more" : "\(results.hits.count) matching events").font(.caption)
                    Spacer()
                    if workspace.searchSize != workspace.snapshot?.size { Text("New log content available · search again").font(.caption).foregroundStyle(.secondary) }
                }
                if results.hits.isEmpty { ContentUnavailableView.search(text: workspace.query) }
                else {
                    List(results.hits) { hit in
                        Button { workspace.navigate(hit) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack { Label(hit.event.title, systemImage: hit.event.kind.symbol).fontWeight(.semibold); Spacer(); Text(hit.event.timestamp).font(.caption).foregroundStyle(.secondary) }
                                Text(hit.turnTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Text(hit.preview).font(.system(size: 11, design: .monospaced)).lineLimit(3)
                            }.padding(.vertical, 5).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }.listStyle(.inset)
                }
            } else { ContentUnavailableView("Find the evidence", systemImage: "magnifyingglass", description: Text("Enter a phrase to search the indexed source. Original records remain local.")) }
        }.padding(22).frame(width: 760, height: 560)
            .onAppear { focused = true; if !workspace.query.isEmpty { workspace.runSearch() } }
    }
}
