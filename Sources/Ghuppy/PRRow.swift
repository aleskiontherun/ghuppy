import GhuppyCore
import SwiftUI

struct PRRow: View {
    let pr: PullRequest

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
            .help(pr.url.absoluteString)

            Spacer(minLength: 8)

            Text(pr.authorLogin.map { "\($0) · " } ?? "")
                + Text(pr.mergedAt ?? pr.updatedAt, format: .relative(presentation: .named))
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var badge: some View {
        switch pr.label {
        case .merged: Badge("Merged", color: .purple)
        case .queued(let entry):
            Badge("Queued #\(entry.position)", color: entry.isUnmergeable ? .red : .darkYellow)
                .help(entry.isUnmergeable
                    ? "In the merge queue, but it can't be merged"
                    : "In the merge queue, position \(entry.position)")
        case .draft: Badge("Draft", color: .gray)
        case .conflicts: Badge("Conflicts", color: .red)
        case .changesRequested: Badge("Changes", color: .red)
        case .update:
            Badge("Update", color: .orange)
                .help("Behind its base branch, and has to be brought up to date to merge")
        case .reviewRequired: Badge("Review", color: .orange)
        case .checksRunning: Badge("CI", color: .darkYellow).help("Checks running")
        case .blocked:
            Badge("Blocked", color: .red)
                .help("GitHub won't merge it, for a reason its checks don't show")
        case .ready: Badge("Ready", color: .green)
        case .approved: Badge("Approved", color: .green)
        case nil: Color.clear.frame(width: Badge.width, height: 0)
        }
    }

    @ViewBuilder
    private var checksIcon: some View {
        if pr.mergedAt != nil {
            Image(systemName: "arrow.triangle.merge").foregroundStyle(.purple).help("Merged")
        } else {
            openChecksIcon
        }
    }

    @ViewBuilder
    private var openChecksIcon: some View {
        switch pr.checks {
        case .passing:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Checks passing")
        case .failing:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help("Checks failing")
        case .pending:
            Image(systemName: "clock.fill").foregroundStyle(.orange).help("Checks running")
        case .awaitingApproval:
            Image(systemName: "clock.fill").foregroundStyle(.orange).help("Checks waiting for approval")
        case .none:
            Image(systemName: "circle.dashed").foregroundStyle(.tertiary).help("No checks")
        }
    }
}

private extension Color {
    /// Yellow that stays readable on both light and dark backgrounds.
    static let darkYellow = Color(red: 0.72, green: 0.53, blue: 0.04)
}

private struct Badge: View {
    /// The same for every label, and held on a row without one, so the rows
    /// line up.
    static let width: CGFloat = 76

    let text: String
    let color: Color

    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(width: Self.width)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
    }
}
