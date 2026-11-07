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
            ToolbarItem {
                Button {
                    showLog.toggle()
                } label: {
                    Label(showLog ? "Hide Log" : "Show Log", systemImage: "text.alignleft")
                }
                .help(showLog ? "Hide the log" : "Show the log")
            }
        }
    }
}

struct WorkspaceView: View {
    @Environment(Workspace.self) private var model
    @AppStorage("logHeight") private var logHeight = 180.0
    let showLog: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            directoryBar
            Divider()
            actionBar(pinnedOnly: $model.pinnedOnly, dryRun: $model.dryRun, author: $model.authorFilter)
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
                .help("Change the working directory")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func actionBar(pinnedOnly: Binding<Bool>, dryRun: Binding<Bool>, author: Binding<String?>) -> some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.cleanupAll() }
            } label: {
                Label("Cleanup all", systemImage: "sparkles")
            }
            .help("Rescan the folder, then fetch with prune, delete local branches that were merged, "
                + "pull the default branch and reload pull requests in every repository (⇧⌘K)")

            Toggle("Pinned only", isOn: pinnedOnly)
                .toggleStyle(.checkbox)
                .help("Have Cleanup all act on only the pinned repositories")

            Toggle("Dry run", isOn: dryRun)
                .toggleStyle(.checkbox)
                .help("Report what cleanup would delete and pull without doing it")

            Picker("Author", selection: author) {
                Text("Everyone").tag(String?.none)
                ForEach(model.authors, id: \.self) { login in
                    Text(login).tag(String?.some(login))
                }
            }
            .fixedSize()
            .help("Show only the pull requests of one author")

            Spacer()

            if let activity = model.bulkActivity ?? (model.scanning ? "Scanning…" : nil) {
                Text(activity).foregroundStyle(.secondary)
            } else if model.root != nil {
                Text("^[\(model.repos.count) repository](inflect: true)")
                    .foregroundStyle(.secondary)
            }
            Button {
                model.refresh()
            } label: {
                Group {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Refresh")
            .help("Rescan the folder and reload every repository's status and pull requests, "
                + "without fetching (⌘R)")
        }
        .disabled(model.root == nil || model.bulkActivity != nil)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
                    Text("measuring…")
                }
                if model.measuringSize && model.directorySize != nil {
                    ProgressView().controlSize(.mini)
                }
            }
            .help("Space the working directory takes up on disk")
            if let until = model.rateLimitedUntil {
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("GitHub rate limit, paused until \(until, format: .dateTime.hour().minute())")
                }
                .foregroundStyle(.orange)
                .help("GitHub's rate limit was reached, so no requests go to it until then. "
                    + "Pull requests stay as last loaded, and Cleanup keeps any branch it can't check.")
            }
            Spacer()
            if let free = model.freeSpace {
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive")
                    Text("\(free, format: .byteCount(style: .file)) free")
                }
                .help("Free space on the volume holding the working directory")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
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
