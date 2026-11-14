import AppKit
import GhuppyCore
import SwiftUI

/// The window's toolbar, acting on the selected tab.
struct WorkspaceToolbar: ToolbarContent {
    @Bindable var workspace: Workspace
    @Binding var showLog: Bool
    let authorMenuRequests: Int

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                workspace.startCleanupAll()
            } label: {
                ShortcutHint("⌘G", iconWidth: 24) {
                    FishSpinner(animating: workspace.bulkActivity != nil)
                        .foregroundStyle(Color.primary)
                }
            }
            .buttonStyle(.hoverHighlight)
            // Not disabled while it runs, which would dim the animation:
            // starting another does nothing while one is running.
            .disabled(workspace.root == nil)
            .accessibilityLabel("Ghuppy!")
            .tooltip([
                TooltipLine(text: "Ghuppy!", shortcut: "⌘G"),
                TooltipLine(text: "Ghuppy ’em all!", shortcut: "⇧⌘G"),
            ])
        }
        ToolbarItem(placement: .navigation) {
            Button {
                workspace.refresh()
            } label: {
                ShortcutHint("⌘R") {
                    if workspace.refreshSpinning {
                        ProgressView().controlSize(.small).scaleEffect(1.25)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .imageScale(.large)
                            .foregroundStyle(Color.primary)
                    }
                }
            }
            .buttonStyle(.hoverHighlight)
            .disabled(!workspace.canAct)
            .accessibilityLabel("Refresh")
            .tooltip([
                TooltipLine(text: "Refresh", shortcut: "⌘R"),
                TooltipLine(text: "Refresh all", shortcut: "⇧⌘R"),
            ])
        }
        // Holds the items to the right, where the title would otherwise.
        ToolbarItem(placement: .primaryAction) { Spacer() }
        ToolbarItem(placement: .primaryAction) {
            AuthorMenu(workspace: workspace, requests: authorMenuRequests)
                .modifier(HoverHighlight(pressed: false))
                .tooltip("Author", shortcut: "⌘U")
        }
        ToolbarItem(placement: .primaryAction) {
            ToolbarToggle(isOn: $workspace.pinnedOnly, symbol: "pin", name: "Pinned Only", shortcut: "⌘P")
                .disabled(!workspace.canAct)
        }
        ToolbarItem(placement: .primaryAction) {
            Rectangle()
                .fill(Color.muted)
                .frame(width: 1, height: 18)
                .padding(.horizontal, 8)
        }
        ToolbarItem(placement: .primaryAction) {
            ToolbarToggle(isOn: $workspace.dryRun, symbol: "flask", name: "Dry Run", shortcut: "⇧⌘D")
                .disabled(!workspace.canAct)
        }
        ToolbarItem(placement: .primaryAction) {
            ToolbarToggle(isOn: $showLog, symbol: "text.alignleft", name: "Log", shortcut: "⌘L", fills: false)
        }
    }
}

/// An icon with its shortcut beside it, muted.
private struct ShortcutHint<Icon: View>: View {
    let shortcut: String
    var iconWidth = 20.0
    @ViewBuilder let icon: Icon

    init(_ shortcut: String, iconWidth: Double = 20, @ViewBuilder icon: () -> Icon) {
        self.shortcut = shortcut
        self.iconWidth = iconWidth
        self.icon = icon()
    }

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: iconWidth, height: 20)
            Text(shortcut)
                .font(.title3)
                .foregroundStyle(Color.muted)
        }
    }
}

/// A setting switched on and off by its icon: full colour when on, muted
/// when off, and filled in when on if the symbol has a filled form.
private struct ToolbarToggle: View {
    @Binding var isOn: Bool
    let symbol: String
    let name: String
    let shortcut: String
    var fills = true

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ShortcutHint(shortcut) {
                Image(systemName: isOn && fills ? symbol + ".fill" : symbol)
                    .imageScale(.large)
                    .foregroundStyle(isOn ? Color.primary : Color.muted)
            }
        }
        .buttonStyle(.hoverHighlight)
        .accessibilityLabel(name)
        .accessibilityValue(isOn ? "On" : "Off")
        .tooltip(name.prefix(1) + name.dropFirst().lowercased(), shortcut: shortcut)
    }
}

/// Picks whose pull requests to show. A menu rather than a plain Picker,
/// which in a toolbar can lose sight of its selection and show nothing.
/// Never disabled: it only changes what is shown, so it is no less safe
/// mid-cleanup than scrolling.
private struct AuthorMenu: View {
    @Bindable var workspace: Workspace
    /// Goes up each time the menu is asked to open from the keyboard.
    let requests: Int
    @State private var anchor = PassthroughView()

    var body: some View {
        HStack(spacing: 8) {
            menu
            // Beside the menu, which would leave it out of its label.
            Text("⌘U")
                .font(.title3)
                .foregroundStyle(Color.muted)
                .contentShape(Rectangle())
                .onTapGesture { AuthorPopUp(workspace: workspace).show(from: anchor) }
        }
        .onChange(of: requests) { AuthorPopUp(workspace: workspace).show(from: anchor) }
    }

    private var menu: some View {
        let authors = workspace.authors
        return Menu {
            Picker("Author", selection: $workspace.authorFilter) {
                Label { Text("Everyone") } icon: { Avatars.shared.image(for: nil) }
                    .tag(String?.none)
                ForEach(authors, id: \.self) { login in
                    Label { Text(login) } icon: { Avatars.shared.image(for: login) }
                        .tag(String?.some(login))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Avatars.shared.image(for: workspace.authorFilter)
                Text(workspace.authorFilter ?? "Everyone")
                    .font(.title3)
                    .foregroundStyle(Color.primary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .background(HostedView(view: anchor))
        .task(id: authors) { Avatars.shared.load(authors) }
    }
}

/// The author select's choices opened from the keyboard: a SwiftUI `Menu`
/// can only open by being clicked.
@MainActor
private final class AuthorPopUp: NSObject {
    private let workspace: Workspace

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    func show(from view: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        add("Everyone", login: nil, to: menu)
        workspace.authors.forEach { add($0, login: $0, to: menu) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: view)
    }

    private func add(_ title: String, login: String?, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: #selector(choose), keyEquivalent: "")
        item.target = self
        item.image = Avatars.shared.menuImage(for: login)
        item.representedObject = login
        item.state = login == workspace.authorFilter ? .on : .off
        menu.addItem(item)
    }

    @objc private func choose(_ item: NSMenuItem) {
        workspace.authorFilter = item.representedObject as? String
    }
}

/// Gives a view an `NSView` to anchor AppKit to, which clicks pass through.
private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct HostedView: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ view: NSView, context: Context) {}
}
