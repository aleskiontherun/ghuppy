import AppKit
import SwiftUI

struct LogPane: View {
    @Environment(Workspace.self) private var model

    /// The heights the log can take in the space it shares with the
    /// repository list, which always keeps enough room to stay usable.
    static func heights(sharing available: Double) -> ClosedRange<Double> {
        let shortest = 80.0
        return shortest...max(shortest, available - 120)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if model.actionLogs.isEmpty {
                    Text("Log").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                } else {
                    tabs
                }
                Spacer()
                if let running = model.selectedActionLog, running.isRunning {
                    Button("Stop") { running.stop() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .tooltip("Stop \(running.action.name), and everything it started")
                }
                Button("Clear") { model.clearLog() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(model.visibleLog.isEmpty)
                    .tooltip("Clear log", shortcut: "⌘K")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(model.visibleLog) { line in
                            row(line).id(line.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.visibleLog.last?.id) { _, last in
                    if let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
        .background(.background)
    }

    /// The log itself, then a tab for each action run on this tab.
    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                LogTab(selected: model.selectedLogID == nil) {
                    model.selectedLogID = nil
                } label: {
                    Text("Log")
                }
                ForEach(model.actionLogs) { log in
                    LogTab(selected: model.selectedLogID == log.id,
                           onClose: log.isRunning ? nil : { model.closeLog(log) }) {
                        model.selectedLogID = log.id
                    } label: {
                        Label(log.title, systemImage: log.action.symbol)
                        status(of: log)
                    }
                    .tooltip(log.title)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func status(of log: ActionLog) -> some View {
        switch log.state {
        case .running:
            ProgressView().controlSize(.mini)
        case let .finished(exit):
            Image(systemName: exit.succeeded ? "checkmark" : "xmark")
                .foregroundStyle(exit.succeeded ? Color.softGreen : Color.warmRed)
        case .stopped:
            Image(systemName: "stop.fill")
                .foregroundStyle(Color.muted)
        }
    }

    private func row(_ line: LogLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(line.date, format: .dateTime.hour().minute().second())
                .foregroundStyle(.tertiary)
            if let repo = line.repo {
                Text(repo).foregroundStyle(.secondary)
            }
            Text(line.text)
                .foregroundStyle(line.isError ? Color.warmRed : Color.primary)
        }
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
    }
}

/// One tab along the top of the log, with a close button on hover when it
/// can be closed.
private struct LogTab<Content: View>: View {
    let selected: Bool
    var onClose: (() -> Void)?
    let select: () -> Void
    @ViewBuilder let label: Content

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            label
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .opacity(hovering || selected ? 1 : 0)
                .accessibilityLabel("Close")
            }
        }
        .font(.caption.weight(selected ? .semibold : .regular))
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(selected ? 0.1 : hovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 5))
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
    }
}

/// The divider above the log, draggable to resize it. A `VSplitView` would
/// lose its position on every tab switch, since each tab gets a fresh view.
struct LogResizeHandle: View {
    @Binding var height: Double
    let range: ClosedRange<Double>

    @State private var dragStart: Double?
    @State private var hovering = false

    private var showsResizeCursor: Bool { hovering || dragStart != nil }

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(height: 9)
                    .contentShape(Rectangle())
                    .onHover { hovering = $0 }
                    .gesture(drag)
            }
            // Above the views either side, which the grab area overlaps.
            .zIndex(1)
            .onChange(of: showsResizeCursor) { _, shows in
                if shows { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .onDisappear {
                if showsResizeCursor { NSCursor.pop() }
            }
    }

    /// Measured in the window, because the handle moves with the drag.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStart ?? height.clamped(to: range)
                dragStart = start
                height = (start - value.translation.height).clamped(to: range)
            }
            .onEnded { _ in dragStart = nil }
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
