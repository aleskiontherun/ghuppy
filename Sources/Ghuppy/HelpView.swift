import GhuppyCore
import SwiftUI

/// Opens the help window, from the Help menu.
struct HelpMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Ghuppy Help") { openWindow(id: HelpView.windowID) }
            .keyboardShortcut("/")
    }
}

/// Every action with its shortcut, and how a pull request gets its label,
/// in a window of its own: it's wider than the smallest main window.
struct HelpView: View {
    static let windowID = "help"

    static let textSize = 14.0
    static let titleFont = Font.title2.weight(.semibold)
    static let headingFont = Font.system(size: 12, weight: .semibold)

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .trailing, spacing: 20) {
            HStack(alignment: .top, spacing: 56) {
                ActionList().frame(width: 410)
                LabelDiagram().frame(width: 410)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                // Esc closes it too, as it would a dialog.
                .background {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .hidden()
                }
        }
        .padding(40)
    }
}

private struct Action: Identifiable {
    let name: String
    let description: String
    var shortcut = ""

    var id: String { name }
}

private struct ActionList: View {
    private static let groups: [(title: String, actions: [Action])] = [
        ("Repositories", [
            Action(name: "Cleanup", description: "Prune, delete merged branches, pull", shortcut: "⌘G"),
            Action(name: "Cleanup All", description: "The same, ignoring Pinned Only", shortcut: "⇧⌘G"),
            Action(name: "Refresh", description: "Reload without fetching", shortcut: "⌘R"),
            Action(name: "Refresh All", description: "The same, ignoring Pinned Only", shortcut: "⇧⌘R"),
            Action(name: "Stop All", description: "Stop everything, in every tab", shortcut: "⌃C"),
        ]),
        ("Settings", [
            Action(name: "Pinned Only", description: "Act on pinned repositories alone", shortcut: "⌘P"),
            Action(name: "Dry Run", description: "Report cleanup without doing it", shortcut: "⇧⌘D"),
            Action(name: "Author", description: "Show one person's pull requests", shortcut: "⌘U"),
        ]),
        ("On a repository", [
            Action(name: "Cleanup", description: "Clean up this repository alone"),
            Action(name: "Pin", description: "Keep it at the top of the list"),
        ]),
        ("Log", [
            Action(name: "Show or Hide", description: "Toggle the log", shortcut: "⌘L"),
            Action(name: "Clear", description: "Empty the log", shortcut: "⌘K"),
        ]),
        ("Tabs and windows", [
            Action(name: "New Tab", description: "Open another working directory", shortcut: "⌘T"),
            Action(name: "Close Tab", description: "Close it, or the last window", shortcut: "⌘W"),
            Action(name: "Close Window", description: "Close every tab", shortcut: "⇧⌘W"),
            Action(name: "Switch Tab", description: "Previous or next", shortcut: "⇧⌘[  ⇧⌘]"),
            Action(name: "Help", description: "Show this window", shortcut: "⌘/"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Actions").font(HelpView.titleFont)
            ForEach(Self.groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 7) {
                    Text(group.title)
                        .font(HelpView.headingFont)
                        .foregroundStyle(.secondary)
                    ForEach(group.actions) { action in
                        row(action)
                    }
                }
            }
        }
    }

    private func row(_ action: Action) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(action.name).frame(width: 104, alignment: .leading)
            Text(action.description)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(action.shortcut).foregroundStyle(.secondary)
        }
        .font(.system(size: HelpView.textSize))
    }
}

/// The labels in the order the app tries them, grouped by what they mean.
private struct LabelDiagram: View {
    private typealias Kind = PullRequest.Label

    private static let groups: [(title: String, kinds: [Kind])] = Kind.allCases.reduce(into: []) { groups, kind in
        if groups.last?.title == kind.group {
            groups[groups.count - 1].kinds.append(kind)
        } else {
            groups.append((kind.group, [kind]))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pull request labels").font(HelpView.titleFont)
                Text("Checked from the top. The first that's true sets the label.")
                    .font(.system(size: HelpView.textSize))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Self.groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(group.title)
                            .font(HelpView.headingFont)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                        ForEach(group.kinds, id: \.self) { kind in
                            row(kind)
                        }
                    }
                }
            }
            // The line the checks run down, from the first to the last.
            .background(alignment: .leading) {
                Rectangle()
                    .fill(Color.muted)
                    .frame(width: 1)
                    .padding(.leading, 4)
                    .padding(.vertical, 8)
            }
        }
    }

    private func row(_ kind: Kind) -> some View {
        HStack(spacing: 0) {
            Circle()
                .fill(kind.color)
                .frame(width: 9, height: 9)
                .padding(.trailing, 11)
            Text(kind.condition).font(.system(size: HelpView.textSize))
            Spacer(minLength: 8)
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(Color.muted)
                .padding(.trailing, 8)
            Badge(kind.title, color: kind.color)
        }
    }
}
