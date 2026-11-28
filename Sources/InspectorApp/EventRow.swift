import AppKit
import SwiftUI

#if SWIFT_PACKAGE
    import InspectorCore
#endif

/// One timeline card, with its connector into the enclosing inference cycle.
struct EventRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let event: InspectorEvent
    let selected: Bool
    let inCycle: Bool
    let lastInCycle: Bool
    private var color: Color {
        switch event.kind {
        case .user: .blue
        case .request: .purple
        case .output: .teal
        case .call: .orange
        case .result: .teal
        case .context: .gray
        case .diagnostic: .orange
        }
    }
    private var inset: CGFloat { !inCycle || event.kind == .request ? 0 : event.kind == .result ? 28 : 14 }
    var body: some View {
        HStack(spacing: 0) {
            if inCycle {
                GeometryReader { geometry in
                    Path { path in
                        let x: CGFloat = 9
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: lastInCycle ? 26 : geometry.size.height))
                        path.move(to: CGPoint(x: x, y: 26))
                        path.addLine(to: CGPoint(x: geometry.size.width - 2, y: 26))
                    }.stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    Circle().fill(event.kind == .request ? Color.purple : Color.secondary.opacity(0.45))
                        .frame(width: event.kind == .request ? 7 : 5, height: event.kind == .request ? 7 : 5)
                        .position(x: 9, y: 26)
                }.frame(width: 23 + inset).accessibilityHidden(true)
            }
            card.padding(.vertical, 3)
        }
    }
    private var card: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.kind.symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(
                selected ? .white : color
            )
            .frame(width: 30, height: 30).background(
                color.opacity(selected ? 0.8 : 0.09), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.continuation?.reason ?? event.title).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 8)
                    Text(LogTimestamp.timeOfDay(event.timestamp)).font(.system(size: 10, design: .monospaced))
                        .opacity(0.65)
                }
                if let continuation = event.continuation {
                    Text(continuation.messageDescription).font(.system(size: 11, weight: .medium)).opacity(0.85)
                }
                Text(event.compactSummary.isEmpty ? "No text content" : event.compactSummary).font(
                    .system(size: 11, design: event.kind == .call ? .monospaced : .default)
                ).lineLimit(2).opacity(0.78)
                HStack(spacing: 6) {
                    Text(event.kind.rawValue.uppercased()).font(.system(size: 8, weight: .bold)).tracking(0.8).opacity(
                        0.6)
                    if event.kind == .call {
                        Text(event.linkedEvent == nil ? "· Result not observed" : "· Reported result available").font(
                            .system(size: 9)
                        ).opacity(0.7)
                    }
                    Spacer()
                }
            }
        }.padding(12)
            .background(
                selected
                    ? Color.blue.opacity(colorScheme == .dark ? 0.30 : 0.18)
                    : Color.primary.opacity(event.kind == .request ? 0.055 : 0.025),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9).strokeBorder(
                    selected ? Color.blue.opacity(0.55) : Color.clear, lineWidth: 1)
            }
    }
}
