import AppKit
import SwiftUI

#if SWIFT_PACKAGE
    import InspectorCore
#endif

/// The bottom status bar: monitoring state, size, record count, warnings, and source path.
struct StatusBar: View {
    @Bindable var workspace: Workspace
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield").foregroundStyle(.teal)
            Text(workspace.monitoring ? "Read-only · Monitoring" : "Read-only · Monitoring paused").fontWeight(.medium)
            if let snapshot = workspace.snapshot {
                Text(
                    "· \(ByteCountFormatter.string(fromByteCount: Int64(snapshot.size), countStyle: .file)) · \(snapshot.recordCount.formatted()) records"
                ).foregroundStyle(.secondary)
                if snapshot.hasPartialRecord { Text("· Partial record pending").foregroundStyle(.orange) }
                if workspace.monitorStatus.hasPrefix("Waiting") {
                    Text(workspace.monitorStatus).foregroundStyle(.orange).lineLimit(1).help(workspace.monitorStatus)
                }
                Spacer()
                if !snapshot.warnings.isEmpty {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(
                        snapshot.warnings.joined(separator: "\n"))
                }
                Text(snapshot.url.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).help(
                    snapshot.url.path)
            } else {
                Spacer()
            }
        }.font(.system(size: 10)).padding(.horizontal, 14).padding(.vertical, 9).background(.bar)
    }
}
