import AppKit
import SwiftUI

#if SWIFT_PACKAGE
    import InspectorCore
#endif

/// The selected turn: its header metrics, filters, paging, and inference-cycle timeline.
struct ExecutionTimeline: View {
    @Bindable var workspace: Workspace
    @FocusState private var timelineFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let turn = workspace.turn {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(turn.group == 0 ? "DIAGNOSTICS" : "USER TURN").font(.system(size: 10, weight: .bold))
                            .tracking(1.5).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(turn.requestCount) inference cycles   ·   \(turn.callCount) tool calls").font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(turn.title).font(.system(size: 21, weight: .semibold)).lineLimit(3).textSelection(.enabled)
                    if turn.group == 0 {
                        Text("Unattributed source diagnostics").font(.system(size: 10)).foregroundStyle(.secondary)
                    } else {
                        let metrics = turn.metrics
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 24) { turnMetrics(metrics, inferenceCount: turn.requestCount) }
                            VStack(alignment: .leading, spacing: 8) {
                                turnMetrics(metrics, inferenceCount: turn.requestCount)
                            }
                        }
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                HStack(spacing: 12) {
                    Picker("Show", selection: Binding(get: { workspace.filter }, set: { workspace.setFilter($0) })) {
                        ForEach(EventFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.frame(maxWidth: 210)
                    Text("\(workspace.visibleEvents.count) events").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if workspace.following {
                        Label("Following", systemImage: "dot.radiowaves.left.and.right").font(.caption).foregroundStyle(
                            .teal)
                        Button("Pause") { workspace.following = false }
                    } else {
                        Button(
                            workspace.newEvents > 0 ? "Return to Live · \(workspace.newEvents) new" : "Return to Live"
                        ) {
                            workspace.monitoring = true
                            workspace.followLatest()
                        }
                        .help("Follow the newest event. Scrolling or selecting a card pauses following (⇧⌘L).")
                    }
                }.controlSize(.small).padding(.horizontal, 16).padding(.vertical, 9)
                if workspace.pageCount > 1 {
                    HStack {
                        Button("Previous events") {
                            workspace.following = false
                            workspace.timelinePage = max(0, workspace.timelinePage - 1)
                        }.disabled(workspace.timelinePage == 0)
                        Spacer()
                        Text("Page \(workspace.timelinePage + 1) of \(workspace.pageCount)").font(.caption)
                        Spacer()
                        Button("Next events") {
                            workspace.following = false
                            workspace.timelinePage = min(workspace.pageCount - 1, workspace.timelinePage + 1)
                        }.disabled(workspace.timelinePage + 1 >= workspace.pageCount)
                    }.controlSize(.small).padding(.horizontal, 16).padding(.bottom, 8)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        // Eager layout keeps the document's measured heights stable during
                        // selection; List's estimated offscreen row heights can shift it.
                        VStack(spacing: 0) {
                            ForEach(workspace.visibleCycles) { cycle in
                                if let number = cycle.number {
                                    HStack(spacing: 8) {
                                        Image(systemName: number == 1 ? "arrow.turn.down.right" : "arrow.down")
                                        Text("INFERENCE \(number)").tracking(1)
                                        Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1)
                                        Label(
                                            cycle.completion?.label ?? "Finish unavailable",
                                            systemImage: cycle.completion == nil ? "questionmark.circle" : "link"
                                        )
                                        .font(.system(size: 10, weight: .medium)).lineLimit(1)
                                        .foregroundStyle(
                                            cycle.completion?.finishReason == "length" ? Color.orange : Color.secondary
                                        )
                                        .help(
                                            cycle.completion.map {
                                                "finish_reason=\($0.finishReason ?? "unavailable") · reported by oMLX. "
                                                    + $0.association
                                            }
                                                ?? "No reliably associated server completion record. Scheduler stop is not a server finish reason."
                                        )
                                    }.font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                                        .padding(.top, 12).padding(.bottom, 6)
                                }
                                ForEach(cycle.events) { event in
                                    Button {
                                        timelineFocused = true
                                        workspace.clickEvent(event)
                                    } label: {
                                        EventRow(
                                            event: event, selected: workspace.eventID == event.id,
                                            inCycle: cycle.number != nil,
                                            lastInCycle: cycle.events.last?.id == event.id
                                        )
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .id(event.id)
                                    .accessibilityAddTraits(workspace.eventID == event.id ? .isSelected : [])
                                }
                            }
                        }.padding(.horizontal, 14).padding(.bottom, 12)
                    }
                    .onScrollPhaseChange { _, phase in
                        if phase == .interacting || phase == .tracking { workspace.following = false }
                    }
                    .overlay {
                        if workspace.visibleEvents.isEmpty {
                            ContentUnavailableView(
                                "No matching events", systemImage: "line.3.horizontal.decrease",
                                description: Text("Choose another category to see this turn's events."))
                        }
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .focused($timelineFocused)
                    .onMoveCommand { direction in
                        guard direction == .up || direction == .down else { return }
                        workspace.moveEventSelection(by: direction == .down ? 1 : -1)
                    }
                    // Mouse selection never requests a reveal. Keyboard navigation and
                    // explicit “View call / result” navigation still bring targets into view.
                    .onChange(of: workspace.relatedNavigation) {
                        if let id = workspace.eventID {
                            proxy.scrollTo(id, anchor: workspace.following ? .bottom : nil)
                        }
                    }
                    .onAppear { if let id = workspace.eventID { proxy.scrollTo(id) } }
                }.id("\(turn.id)-\(workspace.timelinePage)")
            } else if workspace.displayBoundary != nil {
                ContentUnavailableView {
                    Label("Display cleared", systemImage: "sparkle")
                } description: {
                    Text(
                        workspace.monitoring
                            ? "Waiting for new log activity. Your log and earlier history are preserved."
                            : "Monitoring is paused. Resume it to see new activity.")
                } actions: {
                    if !workspace.monitoring {
                        Button("Resume Monitoring") {
                            workspace.monitoring = true
                            workspace.followLatest()
                        }
                    }
                    Button("Show History") { workspace.showHistory() }
                }
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "waveform.path").font(.system(size: 52, weight: .ultraLight)).foregroundStyle(
                        .teal)
                    Text("Follow the evidence.").font(.system(size: 28, weight: .semibold))
                    Text(
                        "Turn verbose inference logs into a readable execution history.\nInspect requests, model output, and tool interactions."
                    )
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).lineSpacing(4)
                    Button("Open an oMLX Log…") { workspace.open() }.buttonStyle(.borderedProminent).controlSize(.large)
                        .tint(.teal)
                    Text("LOCAL  ·  READ-ONLY  ·  PRIVATE").font(.system(size: 10, weight: .medium)).tracking(1.2)
                        .foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(Color(nsColor: .textBackgroundColor))
    }
    @ViewBuilder private func turnMetrics(_ metrics: TurnMetrics, inferenceCount: Int) -> some View {
        Label {
            HStack(spacing: 6) {
                Text(metrics.contextLabel).foregroundStyle(.secondary)
                Text(metrics.contextValue).fontWeight(.semibold)
            }
        } icon: {
            Image(systemName: "chart.bar.xaxis").foregroundStyle(.secondary)
        }
        .font(.system(size: 12)).fixedSize().help(metrics.contextHelp)
        Label {
            HStack(spacing: 6) {
                Text(metrics.durationLabel).foregroundStyle(.secondary)
                Text(metrics.durationValue).fontWeight(.semibold)
            }
        } icon: {
            Image(systemName: "clock").foregroundStyle(.secondary)
        }
        .font(.system(size: 12)).monospacedDigit().fixedSize().help(metrics.durationHelp)
        Label {
            HStack(spacing: 6) {
                Text("Inferences").foregroundStyle(.secondary)
                Text(inferenceCount.formatted()).fontWeight(.semibold)
            }
        } icon: {
            Image(systemName: "cpu").foregroundStyle(.secondary)
        }
        .font(.system(size: 12)).monospacedDigit().fixedSize()
        .help("Total inference requests observed in this turn, across all timeline pages and filters.")
    }
}
