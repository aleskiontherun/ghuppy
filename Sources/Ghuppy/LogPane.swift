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
            HStack {
                Text("Log").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { model.clearLog() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(model.log.isEmpty)
                    .tooltip("Clear log", shortcut: "⌘K")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(model.log) { line in
                            row(line).id(line.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.log.last?.id) { _, last in
                    if let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
        .background(.background)
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
