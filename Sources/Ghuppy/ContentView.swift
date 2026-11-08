import GhuppyCore
import SwiftUI

/// The window: a tab bar when there is more than one tab, the selected
/// tab's workspace, and the toolbar shared by all of them.
struct ContentView: View {
    @Environment(Tabs.self) private var tabs
    @AppStorage("showLog") private var showLog = true

    var body: some View {
        let workspace = tabs.selected
        VStack(spacing: 0) {
            TabBar()
            Divider()
            WorkspaceView(showLog: showLog)
                .environment(workspace)
                .id(workspace.id)
        }
        .navigationTitle(workspace.root.map { "Ghuppy — \($0.lastPathComponent)" } ?? "Ghuppy")
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            tabs.selected.refreshIfStale()
        }
        .toolbar {
            WorkspaceToolbar(workspace: workspace, showLog: $showLog, authorMenuRequests: tabs.authorMenuRequests)
        }
    }
}

struct WorkspaceView: View {
    @Environment(Workspace.self) private var model
    @AppStorage("logHeight") private var logHeight = 180.0
    let showLog: Bool

    var body: some View {
        VStack(spacing: 0) {
            directoryBar
            Divider()
            GeometryReader { proxy in
                let heights = LogPane.heights(sharing: proxy.size.height)
                VStack(spacing: 0) {
                    repositoryList
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showLog {
                        LogResizeHandle(height: $logHeight, range: heights)
                        LogPane()
                            .frame(height: logHeight.clamped(to: heights))
                    }
                }
            }
            if model.root != nil {
                Divider()
                statusBar
            }
        }
        // Each tab has a view of its own, so this runs on launch for the tab
        // selected then, and on switching to a tab.
        .task { model.refreshIfStale() }
        .task { await model.watchPullRequests() }
    }

    private var directoryBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            if let root = model.root {
                Text(root.path)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            } else {
                Text("No working directory selected")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.root == nil {
                Button("Select Working Directory…") { model.chooseRoot() }
            } else {
                Button {
                    model.chooseRoot()
                } label: {
                    Label("Change Working Directory…", systemImage: "pencil")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .tooltip("Change folder")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// The working directory's size on disk and the free space left on its
    /// volume, refreshed after each refresh and cleanup, when something under
    /// the directory changes, and, for the free space, every second.
    private var statusBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                if let size = model.directorySize {
                    Text(size, format: .byteCount(style: .file))
                } else {
                    Text(model.stopped ? "not measured" : "measuring…")
                }
                if model.measuringSize && model.directorySize != nil {
                    ProgressView().controlSize(.mini)
                }
            }
            .tooltip("Size on disk")
            Spacer()
            if let activity = model.bulkActivity ?? (model.scanning ? "Scanning…" : nil) {
                Text(activity)
            } else if model.stopped && model.repos.isEmpty {
                Text("Stopped")
            } else {
                Text("^[\(model.repos.count) repository](inflect: true)")
            }
            if let until = model.rateLimitedUntil {
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("GitHub rate limit, paused until \(until, format: .dateTime.hour().minute())")
                }
                .foregroundStyle(Color.logoOrange)
                .tooltip("GitHub's rate limit was reached")
            }
            Spacer()
            if let free = model.freeSpace {
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive")
                    Text("\(free, format: .byteCount(style: .file)) free")
                }
                .tooltip("Free space")
            }
        }
        // Finder's status bar, which this one sits alongside on the desktop.
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 27)
        // Reading free space is one statfs call, so it is polled the way
        // Finder's status bar does, for as long as the bar is on screen.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                model.refreshFreeSpace()
                await model.refreshRateLimit()
            }
        }
    }

    @ViewBuilder
    private var repositoryList: some View {
        if !model.missingTools.isEmpty {
            ContentUnavailableView(
                "Missing \(model.missingTools.joined(separator: " and "))",
                systemImage: "exclamationmark.triangle",
                description: Text("Install it (for example with Homebrew) and relaunch Ghuppy.")
            )
        } else if model.root == nil {
            ContentUnavailableView {
                Label("Select a working directory", systemImage: "folder.badge.questionmark")
            } description: {
                Text("Ghuppy lists every git repository under it.")
            } actions: {
                Button("Select…") { model.chooseRoot() }
            }
        } else if model.repos.isEmpty && !model.isRefreshing {
            ContentUnavailableView("No repositories", systemImage: "tray",
                                   description: Text("No git repositories were found under this folder."))
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(model.orderedRepos) { repo in
                        RepoCard(repo: repo)
                    }
                }
                .padding(16)
            }
        }
    }
}
