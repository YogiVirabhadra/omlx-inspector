import SwiftUI
import AppKit
#if SWIFT_PACKAGE
    import InspectorCore
#endif

/// Stored by event in the workspace, independently of the currently displayed representation.
@MainActor @Observable final class StructuredViewState {
    var expandedPaths: Set<String> = ["/messages"]
    var selectedPath: String?
}

/// A compact native hierarchy above a separately scrollable complete-value reader.
/// Expanding nodes never lays out their large string contents.
struct StructuredInspector: View {
    let root: StructuredValue
    let identity: String
    @Bindable var state: StructuredViewState
    private var selected: StructuredValue? {
        guard let path = state.selectedPath else { return nil }
        return root.node(at: path)
    }
    @State private var value = ""
    @State private var valueReady = false
    @State private var visibleCharacters = Workspace.textPageCharacters
    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Select a field to read its complete value.")
                    Spacer(minLength: 0)
                    if root.children.first(where: { $0.key == "messages" })?.children.contains(where: \.isNewMessage)
                        == true
                    {
                        Text("NEW = added context").foregroundStyle(.teal)
                    }
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(10)
                NativeOutline(root: root, state: state)
            }.frame(minHeight: 180, idealHeight: 340, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 0) {
                if let selected {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(selected.label).font(.system(size: 12, weight: .semibold))
                            Text(selected.id.isEmpty ? "/ (root)" : selected.id)
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                .lineLimit(2).textSelection(.enabled).help(selected.id)
                        }
                        Spacer()
                        Button("Copy value") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(value, forType: .string)
                        }.controlSize(.small).disabled(!valueReady).help(
                            "Copy this field's complete value, including text not yet displayed")
                    }.padding(10)
                    Divider()
                    if valueReady {
                        NativeText(text: String(value.prefix(visibleCharacters)), identity: identity + selected.id)
                        if value.count > visibleCharacters {
                            HStack {
                                Text("More content is available.").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Load more") { visibleCharacters += Workspace.textPageCharacters }.controlSize(
                                    .small)
                            }.padding(10)
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    VStack(spacing: 9) {
                        Image(systemName: "list.bullet.indent").font(.title2).foregroundStyle(.teal)
                        Text("Explore a message or field").font(.system(size: 13, weight: .medium))
                        Text("Expand a row to see its fields. Select any row to read or copy its complete value here.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(minHeight: 160, idealHeight: 230, maxHeight: .infinity)
        }
        .task(id: selected?.id) {
            valueReady = false
            value = ""
            visibleCharacters = Workspace.textPageCharacters
            guard let selected else { return }
            let complete = await Task.detached(priority: .userInitiated) { selected.completeText }.value
            guard !Task.isCancelled else { return }
            value = complete
            valueReady = true
        }
    }
}

/// An `NSOutlineView` over a ``StructuredValue`` tree. Rows are created lazily, so very large
/// payloads stay responsive. Expansion and selection are mirrored into ``StructuredViewState``.
struct NativeOutline: NSViewRepresentable {
    let root: StructuredValue
    let state: StructuredViewState
    func makeCoordinator() -> Coordinator { Coordinator(state: state) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let outline = NSOutlineView()
        let field = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("field"))
        field.title = "Field"
        field.width = 205
        field.minWidth = 150
        let preview = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("preview"))
        preview.title = "Value preview"
        preview.width = 230
        preview.minWidth = 120
        outline.addTableColumn(field)
        outline.addTableColumn(preview)
        outline.outlineTableColumn = field
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.rowHeight = 28
        outline.indentationPerLevel = 14
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = false
        outline.style = .fullWidth
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.setAccessibilityLabel("Structured evidence hierarchy")
        scroll.documentView = outline
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let outline = scroll.documentView as? NSOutlineView else { return }
        let coordinator = context.coordinator
        guard coordinator.root !== root else { return }
        coordinator.restoring = true
        defer { coordinator.restoring = false }
        coordinator.root = root
        outline.reloadData()
        func restore(_ nodes: [StructuredValue]) {
            for node in nodes where state.expandedPaths.contains(node.id) {
                outline.expandItem(node)
                restore(node.children)
            }
        }
        restore(coordinator.roots)
        if let path = state.selectedPath, let node = root.node(at: path) {
            let row = outline.row(forItem: node)
            if row >= 0 {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outline.scrollRowToVisible(row)
            }
        }
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        // View teardown must not overwrite the saved event state with a deselection.
        coordinator.restoring = true
        (scroll.documentView as? NSOutlineView)?.delegate = nil
        (scroll.documentView as? NSOutlineView)?.dataSource = nil
    }
    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var root: StructuredValue?
        let state: StructuredViewState
        var restoring = false
        var roots: [StructuredValue] {
            guard let root else { return [] }
            return root.kind == .object ? root.children : [root]
        }
        init(state: StructuredViewState) { self.state = state }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? StructuredValue)?.children.count ?? roots.count
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if let node = item as? StructuredValue { return node.children[index] }
            return roots[index]
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? StructuredValue)?.children.isEmpty == false
        }
        func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?)
            -> Any?
        {
            guard let node = item as? StructuredValue else { return nil }
            return tableColumn?.identifier.rawValue == "field" ? node.label : node.preview
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? StructuredValue, let column = tableColumn else { return nil }
            let isField = column.identifier.rawValue == "field"
            let cell =
                (outlineView.makeView(withIdentifier: column.identifier, owner: self) as? OutlineCell) ?? OutlineCell()
            cell.identifier = column.identifier
            let text: NSTextField
            if let existing = cell.textField {
                text = existing
            } else {
                text = NSTextField(labelWithString: "")
                text.translatesAutoresizingMaskIntoConstraints = false
                text.lineBreakMode = .byTruncatingTail
                cell.addSubview(text)
                cell.textField = text
                NSLayoutConstraint.activate([
                    text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
                    text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            text.stringValue = isField ? node.label + (node.isNewMessage ? "  • NEW" : "") : node.preview
            text.font =
                isField
                ? .systemFont(ofSize: 11, weight: node.isNewMessage ? .semibold : .regular)
                : .monospacedSystemFont(ofSize: 10, weight: .regular)
            cell.normalColor = isField ? (node.isNewMessage ? .systemTeal : .labelColor) : .secondaryLabelColor
            text.setAccessibilityLabel(text.stringValue)
            cell.toolTip =
                isField
                ? node.id + (node.isNewMessage ? " · Newly introduced since the preceding inference" : "")
                : node.preview
            return cell
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !restoring, let outline = notification.object as? NSOutlineView else { return }
            state.selectedPath = (outline.item(atRow: outline.selectedRow) as? StructuredValue)?.id
        }
        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !restoring, let node = notification.userInfo?["NSObject"] as? StructuredValue else { return }
            state.expandedPaths.insert(node.id)
        }
        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !restoring, let node = notification.userInfo?["NSObject"] as? StructuredValue else { return }
            state.expandedPaths.remove(node.id)
        }
    }
}

/// Keep the NEW accent readable against native selected-row backgrounds in both appearances.
@MainActor private final class OutlineCell: NSTableCellView {
    var normalColor: NSColor = .labelColor { didSet { updateColor() } }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { updateColor() } }
    private func updateColor() {
        textField?.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : normalColor
    }
}
