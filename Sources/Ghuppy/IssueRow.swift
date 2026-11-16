import GhuppyCore
import SwiftUI

/// How each issue label looks and reads.
extension Issue.Label {
    var title: String {
        switch self {
        case .open: "Open"
        case .closed: "Closed"
        case .notPlanned: "Not planned"
        case .duplicate: "Duplicate"
        }
    }

    var color: Color {
        switch self {
        case .open: .softGreen
        case .closed: .softPurple
        case .notPlanned, .duplicate: .gray
        }
    }

    /// GitHub's own icon for the state, near enough.
    var symbol: String {
        switch self {
        case .open: "smallcircle.filled.circle"
        case .closed: "checkmark.circle"
        case .notPlanned: "slash.circle"
        case .duplicate: "square.on.square"
        }
    }
}

/// An issue, laid out as `PRRow` lays out a pull request, so the two line up.
struct IssueRow: View {
    let issue: Issue
    let github: GitHubRepo

    @State private var hovering = false

    var body: some View {
        let label = issue.label
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Badge(label.title, color: label.color)
            Image(systemName: label.symbol)
                .foregroundStyle(label.color)
                .frame(width: 14)
            Link(destination: issue.url) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("#\(issue.number)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text(issue.title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 8)

            Text(issue.authorLogin.map { "\($0) · " } ?? "")
                + Text(issue.closedAt ?? issue.updatedAt, format: .relative(presentation: .named))

            RowPinButton(number: issue.number, kind: .issue, repo: github, rowHovered: hovering)
        }
        .font(.callout)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
