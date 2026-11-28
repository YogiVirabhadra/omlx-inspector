import AppKit
import SwiftUI

#if SWIFT_PACKAGE
    import InspectorCore
#endif

/// The Executions sidebar: inferred conversations and their user turns.
struct ExecutionSidebar: View {
    @Bindable var workspace: Workspace
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("EXECUTIONS").font(.system(size: 10, weight: .bold)).tracking(1.5).foregroundStyle(.secondary)
                Text(workspace.snapshot?.url.lastPathComponent ?? "No log open").font(.title3.weight(.semibold))
                    .lineLimit(1)
                if let snapshot = workspace.displaySnapshot {
                    Text("\(snapshot.requestCount) requests · \(snapshot.callCount) tool calls").font(.caption)
                        .foregroundStyle(
                            .secondary)
                } else {
                    Text("Explore what your agent did.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(18)
            Divider()
            if let snapshot = workspace.displaySnapshot {
                let groups = Dictionary(grouping: snapshot.turns, by: \.group)
                List(
                    selection: Binding(get: { workspace.turnID }, set: { workspace.showTurn($0) })
                ) {
                    ForEach(groups.keys.sorted(), id: \.self) { group in
                        Section(group == 0 ? "Diagnostics" : "Conversation \(group) · inferred") {
                            ForEach(groups[group] ?? []) { turn in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(turn.title).font(.system(size: 12, weight: .medium)).lineLimit(3)
                                    HStack(spacing: 9) {
                                        Label("\(turn.requestCount)", systemImage: "cpu")
                                        Label("\(turn.callCount)", systemImage: "wrench.and.screwdriver")
                                        Spacer(minLength: 0)
                                        Text(LogTimestamp.timeOfDay(turn.observed, includingSeconds: false))
                                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                                }.padding(.vertical, 5).tag(turn.id)
                            }
                        }
                    }
                }.listStyle(.sidebar)
            } else {
                Spacer()
            }
        }
    }
}
