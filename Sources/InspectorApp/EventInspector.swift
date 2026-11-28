import AppKit
import SwiftUI

#if SWIFT_PACKAGE
    import InspectorCore
#endif

/// The Inspector for the selected event: Readable, Structured, and Source representations.
struct EventInspector: View {
    @Bindable var workspace: Workspace
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let event = workspace.event {
                let displayedSource =
                    workspace.mode == .source && workspace.completionSource
                    ? event.completion?.source ?? event.evidence.source : event.evidence.source
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("INSPECTOR").font(.system(size: 10, weight: .bold)).tracking(1.5).foregroundStyle(
                            .secondary)
                        Spacer()
                        Button {
                            workspace.copy()
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }.controlSize(.small).disabled(workspace.detail == nil).help(
                            "Copy the complete selected representation, including text not yet displayed")
                    }
                    Label(event.title, systemImage: event.kind.symbol).font(.title3.weight(.semibold)).textSelection(
                        .enabled)
                    Text(event.note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(
                        horizontal: false, vertical: true)
                    if let id = event.toolID ?? event.requestID {
                        Text(id).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).foregroundStyle(
                            .secondary)
                    }
                    HStack {
                        Text("Lines \(displayedSource.line)–\(displayedSource.endLine)")
                        Spacer()
                        if event.metrics?.previousRequest != nil {
                            Button(
                                event.metrics?.possibleReset == true ? "Comparison candidate →" : "Previous request →"
                            ) {
                                workspace.previousRequest()
                            }.buttonStyle(.link)
                        }
                        if event.linkedEvent != nil {
                            Button(event.kind == .call ? "View result →" : "View call →") { workspace.related() }
                                .buttonStyle(.link)
                        }
                    }.font(.caption)
                    Button("View log record →") {
                        workspace.viewLogRecord(completion: workspace.mode == .source && workspace.completionSource)
                    }
                    .buttonStyle(.link).font(.caption).help("Open this exact source record in Log Records")
                    Picker("Representation", selection: $workspace.mode) {
                        Text("Readable").tag(InspectorMode.readable)
                        Text("Structured").tag(InspectorMode.structured)
                        Text("Source").tag(InspectorMode.source)
                    }.pickerStyle(.segmented).labelsHidden()
                    if workspace.mode == .source, event.completion != nil {
                        Picker("Source record", selection: $workspace.completionSource) {
                            Text("Original event").tag(false)
                            Text("Completion INFO").tag(true)
                        }.pickerStyle(.segmented).labelsHidden()
                    }
                    Text(workspace.mode.purpose)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(18)
                Divider()
                if workspace.detailLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = workspace.detailError {
                    ContentUnavailableView(
                        "Source unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if workspace.mode == .structured, let tree = workspace.detail?.tree,
                    let state = workspace.structuredStates[event.id]
                {
                    StructuredInspector(root: tree, identity: event.id, state: state).id(event.id)
                } else {
                    NativeText(
                        text: String(workspace.text.prefix(workspace.visibleCharacters)),
                        identity:
                            "\(event.id)-\(workspace.mode)-\(workspace.mode == .source && workspace.completionSource)"
                    )
                    if workspace.text.count > workspace.visibleCharacters {
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
                    "Inspect an event", systemImage: "cursorarrow.click",
                    description: Text("Select a request, output, or tool event to see the evidence behind it."))
            }
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}
