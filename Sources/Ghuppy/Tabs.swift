import Foundation
import GhuppyCore
import Observation
import SwiftUI

/// The open tabs, saved to user defaults whenever a tab is opened, closed,
/// moved, selected, pointed at a different folder, has Pinned only switched
/// on or off, or has another author chosen.
@MainActor @Observable
final class Tabs {
    private static let tabsKey = "tabs"
    private static let selectedKey = "selectedTab"
    /// Each tab's Pinned only setting, in the order of `tabsKey`.
    private static let pinnedOnlyKey = "pinnedOnlyTabs"
    /// Each tab's chosen author, in the order of `tabsKey`, empty for everyone.
    private static let authorFilterKey = "authorFilterTabs"
    /// Where the single working directory was kept before there were tabs.
    private static let legacyRootKey = "workingDirectory"

    private(set) var workspaces: [Workspace] = []
    /// Goes up each time the author select is asked to open.
    var authorMenuRequests = 0
    var selectedID: UUID {
        didSet { save() }
    }

    var selected: Workspace {
        workspaces.first { $0.id == selectedID } ?? workspaces[0]
    }

    init() {
        let defaults = UserDefaults.standard
        let paths = defaults.stringArray(forKey: Self.tabsKey)
            ?? defaults.string(forKey: Self.legacyRootKey).map { [$0] }
            ?? []
        let pinnedOnly = defaults.array(forKey: Self.pinnedOnlyKey) as? [Bool] ?? []
        let authors = defaults.stringArray(forKey: Self.authorFilterKey) ?? []
        var workspaces = paths.enumerated().map { index, path in
            // A folder that has since been moved or deleted reopens as a
            // clean tab rather than disappearing along with its position.
            Workspace(root: !path.isEmpty && FileManager.default.fileExists(atPath: path)
                      ? URL(fileURLWithPath: path) : nil,
                      pinnedOnly: pinnedOnly.indices.contains(index) && pinnedOnly[index],
                      authorFilter: authors.indices.contains(index) && !authors[index].isEmpty ? authors[index] : nil)
        }
        if workspaces.isEmpty {
            workspaces = [Workspace()]
        }
        let index = min(max(defaults.integer(forKey: Self.selectedKey), 0), workspaces.count - 1)
        selectedID = workspaces[index].id
        self.workspaces = workspaces
        workspaces.forEach(observe)
    }

    func newTab() {
        let workspace = Workspace()
        observe(workspace)
        let index = workspaces.firstIndex { $0.id == selectedID }.map { $0 + 1 } ?? workspaces.endIndex
        workspaces.insert(workspace, at: index)
        selectedID = workspace.id
    }

    func close(_ workspace: Workspace) {
        guard workspaces.count > 1, let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        // Nothing would show what they write any more.
        workspace.stopActions()
        workspaces.remove(at: index)
        if selectedID == workspace.id {
            selectedID = workspaces[min(index, workspaces.count - 1)].id
        } else {
            save()
        }
    }

    func move(_ workspace: Workspace, to target: Int) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }), index != target else { return }
        workspaces.insert(workspaces.remove(at: index), at: target)
        save()
    }

    func selectNext(_ offset: Int) {
        guard let index = workspaces.firstIndex(where: { $0.id == selectedID }) else { return }
        let count = workspaces.count
        selectedID = workspaces[((index + offset) % count + count) % count].id
    }

    private func observe(_ workspace: Workspace) {
        workspace.onSavedStateChange = { [weak self] in self?.save() }
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(workspaces.map { $0.root?.path ?? "" }, forKey: Self.tabsKey)
        defaults.set(workspaces.map(\.pinnedOnly), forKey: Self.pinnedOnlyKey)
        defaults.set(workspaces.map { $0.authorFilter ?? "" }, forKey: Self.authorFilterKey)
        defaults.set(workspaces.firstIndex { $0.id == selectedID } ?? 0, forKey: Self.selectedKey)
    }
}

/// Finder-style tabs: a rounded track with the selected tab raised in it,
/// and a round + button beside it. Always shown, so + is always in reach.
/// A tab can be dragged along the track to another position.
struct TabBar: View {
    private static let tabSpacing = 2.0
    private static let settle = Animation.snappy(duration: 0.2)

    @Environment(Tabs.self) private var tabs
    @State private var trackWidth = 0.0
    /// A gesture state, so a drag that gets cancelled leaves nothing behind.
    @GestureState(resetTransaction: Transaction(animation: settle))
    private var dragged: (id: UUID, translation: Double)?

    var body: some View {
        let drag = dragged.flatMap { dragged in
            tabs.workspaces.firstIndex { $0.id == dragged.id }
                .map { tabDrag(from: $0, translation: dragged.translation) }
        }
        HStack(spacing: 8) {
            HStack(spacing: Self.tabSpacing) {
                ForEach(Array(tabs.workspaces.enumerated()), id: \.element.id) { index, workspace in
                    let isDragged = index == drag?.index
                    let shift = drag?.shift(ofTabAt: index) ?? 0
                    let offset = isDragged ? drag?.offset ?? 0 : 0
                    TabButton(workspace: workspace, selected: workspace.id == tabs.selectedID)
                        .gesture(reorder(workspace))
                        .offset(x: shift)
                        .animation(Self.settle, value: shift)
                        // After the animation, to stay with the pointer.
                        .offset(x: offset)
                        .zIndex(isDragged ? 1 : 0)
                }
            }
            .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { trackWidth = $0 }
            .padding(3)
            .frame(height: 32)
            .background(Capsule().fill(Color.primary.opacity(0.07)))

            NewTabButton()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func tabDrag(from index: Int, translation: Double) -> TabDrag {
        let count = tabs.workspaces.count
        return TabDrag(index: index, count: count,
                       slot: (trackWidth + Self.tabSpacing) / Double(count),
                       translation: translation)
    }

    /// Measured in the window, because the tab moves with the drag.
    private func reorder(_ workspace: Workspace) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .updating($dragged) { value, dragged, _ in
                dragged = (workspace.id, Double(value.translation.width))
            }
            .onEnded { value in
                guard let index = tabs.workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
                let target = tabDrag(from: index, translation: Double(value.translation.width)).target
                withAnimation(Self.settle) { tabs.move(workspace, to: target) }
            }
    }
}

private struct NewTabButton: View {
    @Environment(Tabs.self) private var tabs

    var body: some View {
        let button = Button {
            tabs.newTab()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .tooltip("New tab", shortcut: "⌘T")

        if #available(macOS 26, *) {
            button.glassEffect(.regular.interactive(), in: Circle())
        } else {
            button
                .background(Circle().fill(Color(nsColor: .controlColor)))
                .shadow(color: .black.opacity(0.15), radius: 1.5, y: 0.5)
        }
    }
}

private struct TabButton: View {
    @Environment(Tabs.self) private var tabs
    let workspace: Workspace
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        ZStack {
            Text(workspace.title)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 26)
                .foregroundStyle(selected ? .primary : .secondary)
            HStack {
                if tabs.workspaces.count > 1 {
                    Button {
                        tabs.close(workspace)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 16, height: 16)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.borderless)
                    .tooltip("Close tab", shortcut: "⌘W")
                    .opacity(hovering ? 1 : 0)
                }
                Spacer()
                if workspace.isRefreshing {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 6)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if selected {
                Capsule()
                    .fill(Color(nsColor: .controlColor))
                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
            } else if hovering {
                Capsule().fill(Color.primary.opacity(0.05))
            }
        }
        .contentShape(Capsule())
        .onTapGesture { tabs.selectedID = workspace.id }
        .onHover { hovering = $0 }
        .tooltip(workspace.root?.path ?? "No working directory selected")
    }
}
