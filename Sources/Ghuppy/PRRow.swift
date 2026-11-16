import GhuppyCore
import SwiftUI

struct PRRow: View {
    let pr: PullRequest
    let github: GitHubRepo

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            badge
            checksIcon
                .frame(width: 14)
            Link(destination: pr.url) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("#\(pr.number)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text(pr.title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .tooltip(pr.headRefName)

            Spacer(minLength: 8)

            Text(pr.authorLogin.map { "\($0) · " } ?? "")
                + Text(pr.mergedAt ?? pr.closedAt ?? pr.updatedAt, format: .relative(presentation: .named))

            RowPinButton(number: pr.number, kind: .pullRequest, repo: github, rowHovered: hovering)
        }
        .font(.callout)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var badge: some View {
        if pr.label == .queued, let entry = pr.mergeQueue {
            Badge("Queued #\(entry.position)", color: entry.isUnmergeable ? .warmRed : .darkYellow)
                .tooltip(entry.isUnmergeable ? "Can't merge from the queue" : "Place in the merge queue")
        } else {
            LabelBadge(label: pr.label)
        }
    }

    @ViewBuilder
    private var checksIcon: some View {
        if pr.mergedAt != nil {
            Image(systemName: "arrow.triangle.merge").foregroundStyle(Color.softPurple).tooltip("Merged")
        } else if pr.closedAt != nil {
            Image(systemName: "xmark.circle").foregroundStyle(.gray).tooltip("Closed without merging")
        } else {
            openChecksIcon
        }
    }

    @ViewBuilder
    private var openChecksIcon: some View {
        switch pr.checks {
        case .passing:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.softGreen).tooltip("Checks passing")
        case .failing:
            Image(systemName: "xmark.circle.fill").foregroundStyle(Color.warmRed).tooltip("Checks failing")
        case .pending:
            Image(systemName: "clock.fill").foregroundStyle(Color.logoOrange).tooltip("Checks running")
        case .awaitingApproval:
            Image(systemName: "clock.fill").foregroundStyle(Color.logoOrange).tooltip("Workflow awaiting approval")
        case .none:
            Image(systemName: "circle.dashed").foregroundStyle(.tertiary).tooltip("No checks")
        }
    }
}
