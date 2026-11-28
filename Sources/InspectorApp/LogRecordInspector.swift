import AppKit
import SwiftUI

#if SWIFT_PACKAGE
    import InspectorCore
#endif

/// Structured and Source representations of the selected log record.
struct LogRecordInspector: View {
    @Bindable var workspace: Workspace
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let record = workspace.selectedRecord {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("RECORD INSPECTOR").font(.system(size: 10, weight: .bold)).tracking(1.5).foregroundStyle(
                            .secondary)
                        Spacer()
                        Button {
                            workspace.copyRecord()
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .controlSize(.small).disabled(workspace.detail == nil).help("Copy the complete representation")
                    }
                    Text(record.timestamp.isEmpty ? "Unframed / partial record" : record.timestamp).font(
                        .title3.weight(.semibold)
                    ).textSelection(.enabled)
                    Text("\(record.level) · \(record.logger)").font(.caption).foregroundStyle(.secondary).textSelection(
                        .enabled)
                    Text(
                        "Lines \(record.source.line)–\(record.source.endLine) · \(record.source.length.formatted()) bytes"
                    ).font(.caption).foregroundStyle(.secondary)
                    if record.context != "-" {
                        Text("Context: \(record.context)").font(.caption).textSelection(.enabled)
                    }
                    if let id = record.requestID {
                        Text(id).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                    Button("Return to executions →") { workspace.browsingMode = .executions }.buttonStyle(.link).font(
                        .caption)
                    Picker("Record representation", selection: $workspace.recordMode) {
                        Text("Structured").tag(RecordInspectorMode.structured)
                        Text("Source").tag(RecordInspectorMode.source)
                    }.pickerStyle(.segmented).labelsHidden()
                    Text(
                        workspace.recordMode == .source
                            ? "The exact original log record"
                            : "Complete request fields, or record metadata and message"
                    )
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(18)
                Divider()
                if workspace.detailLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = workspace.detailError {
                    ContentUnavailableView(
                        "Source unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if workspace.recordMode == .structured, let tree = workspace.detail?.tree,
                    let state = workspace.structuredStates[record.id]
                {
                    StructuredInspector(root: tree, identity: record.id, state: state).id(record.id)
                } else {
                    NativeText(
                        text: String(workspace.recordText.prefix(workspace.visibleCharacters)),
                        identity: "\(record.id)-\(workspace.recordMode)")
                    if workspace.recordText.count > workspace.visibleCharacters {
                        HStack {
                            Text("More content is available.").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Load more") { workspace.visibleCharacters += Workspace.textPageCharacters }
                                .controlSize(.small)
                        }.padding(10)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Inspect a log record", systemImage: "cursorarrow.click",
                    description: Text("Select a record to explore its fields and original source."))
            }
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}
