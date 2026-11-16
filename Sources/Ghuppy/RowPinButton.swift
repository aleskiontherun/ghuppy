import GhuppyCore
import SwiftUI

/// The pin at the end of a pull request or issue row, which keeps it listed
/// once it's merged or closed. Only there under the pointer until it's
/// pinned, but its room is kept either way, so the row doesn't shift.
struct RowPinButton: View {
    let number: Int
    let kind: RowPins.Kind
    let repo: GitHubRepo
    /// Whether the pointer is over the row.
    let rowHovered: Bool

    var body: some View {
        let pins = RowPins.shared
        let pinned = pins.isPinned(number, kind, in: repo)
        Button {
            pins.toggle(number, kind, in: repo)
        } label: {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .imageScale(.small)
                .rotationEffect(.degrees(45))
                .foregroundStyle(pinned ? Color.logoOrange : Color.secondary)
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.hoverHighlight)
        // The highlight's room above and below stays out of the row's height.
        .padding(.vertical, -4)
        .opacity(pinned || rowHovered ? 1 : 0)
        .accessibilityLabel(pinned ? "Unpin" : "Pin")
        .tooltip(pinned ? "Unpin" : kind == .pullRequest ? "Pin, to keep it listed once merged"
                 : "Pin, to keep it listed once closed")
    }
}
