import AppKit
import SwiftUI

/// One line of a tooltip: what it says, and the shortcut beside it.
struct TooltipLine: Hashable {
    let text: String
    var shortcut: String?
}

extension View {
    /// Shows `text`, and the `shortcut` beside it, after the pointer has
    /// rested on the view for a moment. It takes the place of `help`, whose
    /// look and timing are the system's.
    func tooltip(_ text: String, shortcut: String? = nil) -> some View {
        tooltip([TooltipLine(text: text, shortcut: shortcut)])
    }

    /// A tooltip of several lines, each with a shortcut of its own.
    func tooltip(_ lines: [TooltipLine]) -> some View {
        background(TooltipAnchor(lines: lines))
            .accessibilityHint(lines.map(\.text).joined(separator: ", "))
    }
}

private struct TooltipAnchor: NSViewRepresentable {
    let lines: [TooltipLine]

    func makeNSView(context: Context) -> TooltipAnchorView {
        TooltipAnchorView()
    }

    func updateNSView(_ view: TooltipAnchorView, context: Context) {
        view.lines = lines
    }
}

/// Sits behind the view with the tooltip and watches the pointer. A tracking
/// area reports it even with other views on top, and clicks pass through.
private final class TooltipAnchorView: NSView {
    private static let delay = Duration.seconds(1)

    var lines: [TooltipLine] = []
    private var waiting: Task<Void, Never>?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        waiting?.cancel()
        waiting = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled, let self else { return }
            TooltipPanel.shared.show(lines, for: self)
        }
    }

    override func mouseExited(with event: NSEvent) {
        dismiss()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { dismiss() }
    }

    private func dismiss() {
        waiting?.cancel()
        TooltipPanel.shared.hide(for: self)
    }
}

/// The one window tooltips appear in, so they can reach beyond the toolbar
/// or the card they belong to.
@MainActor
private final class TooltipPanel {
    static let shared = TooltipPanel()

    private static let gap = 6.0

    private let panel = NSPanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: true
    )
    private let host = NSHostingView(rootView: TooltipLabel(lines: [], textWidth: 0))
    private weak var owner: NSView?
    private var monitor: Any?

    private init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.contentView = host
        // The panel floats above every app, so it goes when Ghuppy does.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    func show(_ lines: [TooltipLine], for view: NSView) {
        guard NSApp.isActive, let window = view.window, !lines.isEmpty else { return }
        let textWidth = lines.map { TooltipLabel.width(of: $0.text) }.max() ?? 0
        host.rootView = TooltipLabel(lines: lines, textWidth: textWidth)
        let size = host.fittingSize
        let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? anchor

        var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - Self.gap - size.height)
        if origin.y < screen.minY { origin.y = anchor.maxY + Self.gap }
        origin.x = min(max(origin.x, screen.minX + Self.gap), screen.maxX - size.width - Self.gap)

        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFront(nil)
        panel.invalidateShadow()
        owner = view
        // Whatever the pointer or keyboard does next, the tooltip is done.
        monitor = monitor ?? NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.hide() }
            return event
        }
    }

    func hide(for view: NSView) {
        if owner === view { hide() }
    }

    private func hide() {
        panel.orderOut(nil)
        owner = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct TooltipLabel: View {
    private static let fontSize = 13.0
    private static let widestText = 300.0

    let lines: [TooltipLine]
    let textWidth: Double

    /// How wide `text` is on one line, up to where it starts to wrap.
    static func width(of text: String) -> Double {
        let font = NSFont.systemFont(ofSize: fontSize)
        return min(ceil((text as NSString).size(withAttributes: [.font: font]).width) + 1, widestText)
    }

    /// `⇧⌘B` as `⇧ ⌘ B`.
    private func keys(_ shortcut: String) -> String {
        shortcut.map(String.init).joined(separator: " ")
    }

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(lines, id: \.self) { line in
                GridRow {
                    Text(line.text)
                        .foregroundStyle(Color.primary)
                        .frame(width: textWidth, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let shortcut = line.shortcut {
                        Text(keys(shortcut))
                            .foregroundStyle(Color.secondary)
                            .fixedSize()
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
        }
        .font(.system(size: Self.fontSize))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .fixedSize()
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor))
        }
    }
}
