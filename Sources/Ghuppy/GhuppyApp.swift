import AppKit
import SwiftUI

@main
struct GhuppyApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var tabs = Tabs()
    @AppStorage("showLog") private var showLog = true

    var body: some Scene {
        Window("Ghuppy", id: "main") {
            ContentView()
                .environment(tabs)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 900, height: 760)
        // The title stays for the Window menu and Mission Control.
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            // The stock About panel, plus a link to the repository in its credits.
            CommandGroup(replacing: .appInfo) {
                Button("About Ghuppy") {
                    let link = NSMutableAttributedString(string: "github.com/aleskiontherun/ghuppy")
                    link.addAttributes(
                        [.link: URL(string: "https://github.com/aleskiontherun/ghuppy")!,
                         .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)],
                        range: NSRange(location: 0, length: link.length))
                    let centred = NSMutableParagraphStyle()
                    centred.alignment = .center
                    link.addAttribute(.paragraphStyle, value: centred,
                                      range: NSRange(location: 0, length: link.length))
                    NSApp.orderFrontStandardAboutPanel(options: [.credits: link])
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { tabs.newTab() }
                    .keyboardShortcut("t")
            }
            // Replaces the stock Close (⌘W), so ⌘W closes a tab first and
            // only the last tab closes the window, as in a browser.
            CommandGroup(replacing: .saveItem) {
                Button(tabs.workspaces.count > 1 ? "Close Tab" : "Close Window") {
                    if tabs.workspaces.count > 1 {
                        tabs.close(tabs.selected)
                    } else {
                        NSApp.keyWindow?.performClose(nil)
                    }
                }
                .keyboardShortcut("w")
                Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
            }
            // Nothing here prints, and ⌘P has a job in the Repositories menu.
            CommandGroup(replacing: .printItem) {}
            CommandGroup(after: .toolbar) {
                Button(showLog ? "Hide Log" : "Show Log") { showLog.toggle() }
                    .keyboardShortcut("l")
                // Not disabled when the log is empty: reading the log here
                // would rebuild the menus on every line written to it.
                Button("Clear Log") { tabs.selected.clearLog() }
                    .keyboardShortcut("k")
            }
            CommandMenu("Repositories") {
                // The actions look up the tab when they run: a shortcut can
                // fire an action built while another tab was selected.
                Button("Ghuppy!") { tabs.selected.startCleanupAll() }
                    .keyboardShortcut("g")
                Button("Ghuppy ’em all!") { tabs.selected.startCleanupAll(includingUnpinned: true) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Group {
                    Toggle("Pinned Only", isOn: Binding(
                        get: { tabs.selected.pinnedOnly },
                        set: { tabs.selected.pinnedOnly = $0 }
                    ))
                    .keyboardShortcut("p")
                    Toggle("Dry Run", isOn: Binding(
                        get: { tabs.selected.dryRun },
                        set: { tabs.selected.dryRun = $0 }
                    ))
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                }
                .disabled(!tabs.selected.canAct)
                Button("Choose Author…") { tabs.authorMenuRequests += 1 }
                    .keyboardShortcut("u")
                    .disabled(!tabs.selected.canAct)
                Divider()
                Group {
                    Button("Refresh") { tabs.selected.refresh() }
                        .keyboardShortcut("r")
                    Button("Refresh All") { tabs.selected.refresh(includingUnpinned: true) }
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                }
                .disabled(!tabs.selected.canAct)
                Divider()
                Button("Stop All") { tabs.workspaces.forEach { $0.stopAll() } }
                    .keyboardShortcut("c", modifiers: .control)
            }
            CommandGroup(replacing: .help) { HelpMenuButton() }
            CommandGroup(after: .windowArrangement) {
                Button("Show Previous Tab") { tabs.selectNext(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Button("Show Next Tab") { tabs.selectNext(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
            }
        }

        Window("Ghuppy Help", id: HelpView.windowID) {
            HelpView()
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified(showsTitle: true))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when run as a bare executable (`swift run`) rather than
        // from the .app bundle, which would otherwise get no Dock icon or
        // keyboard focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
