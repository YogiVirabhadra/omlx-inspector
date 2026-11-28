import AppKit
import SwiftUI

#if SWIFT_PACKAGE
    import InspectorCore
#endif

/// The application: one window, plus menu commands that act on the shared ``Workspace``.
@main struct OMLXInspectorApp: App {
    @State private var workspace = Workspace()
    var body: some Scene {
        WindowGroup("oMLX Inspector") {
            InspectorWindow(workspace: workspace)
                .frame(minWidth: 940, minHeight: 620)
                .preferredColorScheme(workspace.appearance.colorScheme)
                .onOpenURL { workspace.load($0) }
        }
        .defaultSize(width: 1360, height: 850)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Log…") { workspace.open() }.keyboardShortcut("o")
                Button("Reindex Log") { if let url = workspace.snapshot?.url { workspace.load(url) } }.keyboardShortcut(
                    "r"
                ).disabled(workspace.snapshot == nil || workspace.loading)
            }
            CommandGroup(after: .textEditing) {
                Button("Clear Display") { workspace.clearDisplay() }.keyboardShortcut("k")
                    .disabled(workspace.snapshot == nil || workspace.loading || workspace.pendingReplacement != nil)
                Button("Search…") { workspace.searchPresented = true }.keyboardShortcut("f")
                Button("Return to Live") {
                    workspace.monitoring = true
                    workspace.followLatest()
                }.keyboardShortcut("l", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Toggle("Show Inspector", isOn: $workspace.inspector).keyboardShortcut(
                    "i", modifiers: [.command, .option])
            }
        }
    }
}

extension Appearance {
    /// The scheme to force, or `nil` to follow the system setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
