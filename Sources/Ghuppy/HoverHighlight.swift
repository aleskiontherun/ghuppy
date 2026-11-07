import SwiftUI

/// An icon button with room around it, which lights up under the pointer.
struct HoverHighlightButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(HoverHighlight(pressed: configuration.isPressed))
    }
}

extension ButtonStyle where Self == HoverHighlightButtonStyle {
    static var hoverHighlight: HoverHighlightButtonStyle { HoverHighlightButtonStyle() }
}

struct HoverHighlight: ViewModifier {
    let pressed: Bool

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var opacity: Double {
        guard isEnabled else { return 0 }
        return pressed ? 0.18 : hovering ? 0.1 : 0
    }

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(opacity), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }
    }
}
