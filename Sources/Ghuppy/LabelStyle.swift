import GhuppyCore
import SwiftUI

/// How each label looks and reads, in the pull request rows and in Help.
extension PullRequest.Label {
    var title: String {
        switch self {
        case .merged: "Merged"
        case .queued: "Queued #1"
        case .draft: "Draft"
        case .changesRequested: "Changes"
        case .conflicts: "Conflicts"
        case .checksFailed: "Failed"
        case .update: "Update"
        case .checksAwaitApproval: "Approve"
        case .reviewRequired: "Review"
        case .checksRunning: "CI"
        case .blocked: "Blocked"
        case .ready: "Ready"
        case .approved: "Approved"
        case .unknown: "…"
        }
    }

    var color: Color {
        switch self {
        case .merged: .softPurple
        case .queued, .checksRunning: .darkYellow
        case .draft, .unknown: .gray
        case .changesRequested, .conflicts, .checksFailed, .blocked: .warmRed
        case .update, .checksAwaitApproval, .reviewRequired: .logoOrange
        case .ready, .approved: .softGreen
        }
    }

    /// What has to be true for the label, as Help lists it.
    var condition: String {
        switch self {
        case .merged: "Merged"
        case .queued: "In the merge queue"
        case .draft: "A draft"
        case .changesRequested: "Changes requested"
        case .conflicts: "Has conflicts"
        case .checksFailed: "Checks failed"
        case .update: "Behind its base branch"
        case .checksAwaitApproval: "Workflow awaiting approval"
        case .reviewRequired: "Review required"
        case .checksRunning: "Checks running"
        case .blocked: "GitHub blocks the merge"
        case .ready: "Nothing in the way"
        case .approved: "Approved"
        case .unknown: "State not known yet"
        }
    }

    /// The tooltip, for a label whose title doesn't say it all.
    var tooltip: String? {
        switch self {
        case .checksFailed, .update, .checksAwaitApproval, .checksRunning, .blocked, .unknown: condition
        default: nil
        }
    }

    /// The heading Help groups the label under.
    var group: String {
        switch self {
        case .merged, .queued, .draft: "Past asking for anything"
        case .changesRequested, .conflicts, .checksFailed, .update: "Takes a new commit"
        case .checksAwaitApproval, .reviewRequired: "Waits on someone"
        case .checksRunning, .blocked: "Waits on GitHub"
        case .ready, .approved: "Good news"
        case .unknown: "Otherwise"
        }
    }
}

struct LabelBadge: View {
    let label: PullRequest.Label

    var body: some View {
        Badge(label.title, color: label.color)
            .tooltip(label.tooltip.map { [TooltipLine(text: $0)] } ?? [])
    }
}

struct Badge: View {
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
            .frame(width: 76) // The same for every label, so the rows line up.
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
    }
}

extension Color {
    /// Yellow that stays readable on both light and dark backgrounds.
    static let darkYellow = Color(red: 0.72, green: 0.53, blue: 0.04)
}
