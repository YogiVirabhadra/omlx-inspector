import AppKit
import SwiftUI

/// A read-only, selectable `NSTextView`. Handles large text far better than SwiftUI `Text`.
/// Scrolls back to the top only when `identity` changes, not when the same content grows.
struct NativeText: NSViewRepresentable {
    let text: String
    let identity: String
    final class Coordinator {
        var identity = ""
        var text = ""
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = NSSize(width: 14, height: 16)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.usesFindBar = true
        view.isAutomaticLinkDetectionEnabled = false
        view.setAccessibilityLabel("Event evidence text")
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if context.coordinator.text != text || context.coordinator.identity != identity {
            let reset = context.coordinator.identity != identity
            view.string = text
            view.textColor = .textColor
            view.backgroundColor = .textBackgroundColor
            if reset { view.scrollToBeginningOfDocument(nil) }
            context.coordinator.text = text
            context.coordinator.identity = identity
        }
    }
}
