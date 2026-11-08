import AppKit
import Observation
import GhuppyCore

struct LogLine: Identifiable {
    let id = UUID()
    let date = Date()
    let repo: String?
    let text: String
    let isError: Bool
}

@MainActor @Observable
final class RepoState: Identifiable {
    let git: GitRepo
    let name: String
    var github: GitHubRepo?
    var status = LocalStatus()
    /// The open pull requests, the ones in the merge queue last.
    var pullRequests: [PullRequest] = []
    /// The latest merged pull requests, the last merged first.
    var mergedPullRequests: [PullRequest] = []
    var prError: String?
    /// Why the merge queue and merged pull requests last failed to load, nil
    /// once they load again.
    var extrasError: String?
    var loadingPRs = false
    /// How many refreshes are reloading the repository right now: the tab's
    /// and its own. A cleanup's reload isn't counted.
    var refreshes = 0
    var isRefreshing: Bool { refreshes > 0 }
    /// Whether the open pull requests have loaded at least once, which tells
    /// an empty list from one still to come, or that there are none to load.
    /// Later reloads stay out of sight. Even a refresh of only the pinned
    /// repositories loads the ones still without it.
    var prsLoaded = false
    /// What the repository is doing right now, shown next to its name.
    var activity: String?
    /// The outcome of the last cleanup.
    var result: (text: String, isError: Bool)?
    /// The repository's size on disk, nil until first measured.
    var size: Int64?
    /// How many worktrees and branches it has, nil until first counted.
    var refCounts: RefCounts?

    nonisolated var id: URL { git.path }

    init(path: URL, name: String) {
        git = GitRepo(path: path)
        self.name = name
    }
}

/// One tab: a working directory and the repositories under it.
@MainActor @Observable
final class Workspace: Identifiable {
    /// How many repositories are fetched or cleaned at once.
    private static let concurrency = 6
    /// How long, in seconds, a tab that comes back on screen goes without a
    /// refresh after the last one.
    private static let refreshedRecently: TimeInterval = 60
    /// How long, in seconds, the tree stays quiet before the repositories
    /// are discovered again: long enough for a clone to finish, so its card
    /// doesn't load half a repository.
    private static let treeSettles: TimeInterval = 3
    /// How long, in seconds, a tree that never goes quiet is waited for.
    private static let treeSettlesAtMost: TimeInterval = 30
    /// How often the tab on screen asks GitHub whether its pull requests
    /// changed. Asking costs nothing while they haven't, and GitHub's answers
    /// can be up to a minute old anyway.
    private static let changeCheckInterval: Duration = .seconds(30)

    let id = UUID()
    var root: URL? {
        didSet { onSavedStateChange?() }
    }
    var repos: [RepoState] = []
    /// `repos` as listed: pinned ones first, each group in path order.
    var orderedRepos: [RepoState] {
        let pins = Pins.shared
        return repos.filter { pins.isPinned($0.git.path) } + repos.filter { !pins.isPinned($0.git.path) }
    }
    /// The repositories that Cleanup and Refresh act on.
    private var scopedRepos: [RepoState] {
        pinnedOnly ? orderedRepos.filter { Pins.shared.isPinned($0.git.path) } : orderedRepos
    }
    /// Whether Refresh, the settings and the author select can be used.
    var canAct: Bool { root != nil && bulkActivity == nil }
    var log: [LogLine] = []
    var scanning = false
    var bulkActivity: String?
    /// Whether anything on the tab is being brought up to date: a refresh, or
    /// a cleanup, which rescans and reloads pull requests along the way.
    var isRefreshing: Bool {
        refreshSlot.isRunning || bulkActivity != nil || scanning || repos.contains(where: \.loadingPRs)
    }
    /// Whether the Refresh button turns: while a refresh runs, but not
    /// beside a Ghuppy ’em all!, whose icon turns instead.
    var refreshSpinning: Bool { refreshSlot.isRunning && bulkActivity == nil }
    /// Whether Cleanup and Refresh act on the pinned repositories only.
    var pinnedOnly: Bool {
        didSet { onSavedStateChange?() }
    }
    var dryRun = false
    /// The author whose pull requests are listed, nil for everyone's.
    var authorFilter: String? {
        didSet { onSavedStateChange?() }
    }
    /// Who the author select offers.
    var authors: [String] {
        PullRequests.authors(of: repos.flatMap { $0.pullRequests + $0.mergedPullRequests }, selected: authorFilter)
    }
    /// The working directory's size on disk, nil until first measured.
    var directorySize: Int64?
    /// Free space on the working directory's volume.
    var freeSpace: Int64?
    var measuringSize = false
    /// When GitHub requests resume, nil while its rate limit isn't pausing them.
    var rateLimitedUntil: Date?
    /// What the Cleanup all running now has freed so far.
    @ObservationIgnored private var freedByCleanupAll: Int64 = 0
    /// How many commits the Cleanup all running now has pulled so far.
    @ObservationIgnored private var pulledByCleanupAll = 0
    @ObservationIgnored private var measurement: Task<Void, Never>?
    @ObservationIgnored private var measurementID: UUID?
    /// Tells when something under the working directory changed.
    @ObservationIgnored private var watcher: (root: URL, watcher: DirectoryWatcher)?
    /// Whether the figures are known to be behind the disk, and the loop
    /// measuring them again while they are.
    @ObservationIgnored private var sizesStale = false
    @ObservationIgnored private var remeasuring: Task<Void, Never>?
    /// What the last discovery found and left out, which tells the changes
    /// that could add or remove a repository from the rest.
    @ObservationIgnored private var lastScan = Discovery.Scan()
    /// Whether the list is known to be behind the disk, and the loop
    /// discovering again while it is.
    @ObservationIgnored private var reposStale = false
    @ObservationIgnored private var rediscovering: Task<Void, Never>?
    @ObservationIgnored private var rediscoveringID: UUID?
    /// When a change that could add or remove a repository last came.
    @ObservationIgnored private var lastTreeChange = Date.distantPast
    private let refreshSlot = RefreshSlot()
    /// Whether Stop All was the last word: what's on screen may be partial.
    private(set) var stopped = false
    /// The cleanups and single-repository refreshes under way, for Stop All
    /// to reach.
    @ObservationIgnored private var cleanups: [UUID: Task<Void, Never>] = [:]
    /// The look for changed pull requests under way, for Stop All to reach.
    @ObservationIgnored private var changeCheck: Task<Void, Never>?
    /// When the last refresh started.
    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored var onSavedStateChange: (() -> Void)?

    var title: String { root?.lastPathComponent ?? "New Tab" }

    var missingTools: [String] {
        [("git", Shell.gitPath), ("gh", Shell.ghPath)].compactMap { $0.1 == nil ? $0.0 : nil }
    }

    init(root: URL? = nil, pinnedOnly: Bool = false, authorFilter: String? = nil) {
        self.root = root
        self.pinnedOnly = pinnedOnly
        self.authorFilter = authorFilter
    }

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder containing git repositories"
        panel.directoryURL = root
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url != root else { return }
        root = url
        repos = []
        authorFilter = nil
        directorySize = nil
        freeSpace = nil
        refresh()
    }

    // MARK: Refreshing

    /// Brings the tab up to date without fetching, in place of any refresh
    /// still running: rediscovers the repositories, reloads the status and
    /// pull requests of the ones in scope, and measures the disk again. With
    /// Pinned only, a repository out of scope still loads the first time, so
    /// its card isn't left waiting.
    func refresh(includingUnpinned: Bool = false) {
        guard root != nil else { return }
        stopped = false
        lastRefresh = .now
        // It discovers anyway, and mustn't find a discovery in its way.
        stopRediscovering()
        refreshSlot.start { [self] in
            while scanning, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard await discover() else { return }
            measureDisk()
            let pins = Pins.shared
            let repos = orderedRepos.filter {
                includingUnpinned || !pinnedOnly || !$0.prsLoaded || pins.isPinned($0.git.path)
            }
            await forEach(repos) { await self.reload($0) }
            let measuring = measurement
            await withTaskCancellationHandler {
                await measuring?.value
            } onCancel: {
                measuring?.cancel()
            }
        }
    }

    /// Refreshes a tab that has just come on screen, by launching, by
    /// switching to it or by switching to the app, unless that wouldn't tell
    /// anything new: it was refreshed moments ago, or is being. A cleanup
    /// running reloads the same repositories.
    func refreshIfStale() {
        guard !refreshSlot.isRunning, bulkActivity == nil,
              Date.now.timeIntervalSince(lastRefresh) >= Self.refreshedRecently else { return }
        refresh()
    }

    /// Reloads the pull requests that GitHub says changed, every so often for
    /// as long as the calling task runs: the tab's view, while it's on
    /// screen. Only the repositories Refresh acts on are looked at, and not
    /// while anything else is bringing them up to date. Stop All stops the
    /// look under way, not the ones to come.
    func watchPullRequests() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.changeCheckInterval)
            guard !Task.isCancelled, !refreshSlot.isRunning, bulkActivity == nil, !scanning,
                  changeCheck == nil else { continue }
            let repos = scopedRepos.filter { $0.prsLoaded && $0.github != nil }
            let check = Task {
                await forEach(repos) { await self.reloadIfChanged($0) }
            }
            changeCheck = check
            await withTaskCancellationHandler {
                await check.value
            } onCancel: {
                check.cancel()
            }
            changeCheck = nil
        }
    }

    private func reloadIfChanged(_ repo: RepoState) async {
        guard let github = repo.github, !repo.loadingPRs, !repo.isRefreshing, repo.activity == nil,
              let look = try? await PullRequestChanges.shared.look(github, cwd: repo.git.path), look.changed,
              !Task.isCancelled, !repo.loadingPRs, !repo.isRefreshing, repo.activity == nil else { return }
        await refreshPRs(repo, after: look)
    }

    /// Re-measures the working directory's size, each repository's share of
    /// it and the free space beside it, in one walk off the main actor. A
    /// measurement still running is cancelled, so the figures shown are
    /// always the latest root's. Each repository's worktrees and branches
    /// are counted meanwhile, so they keep up with the size beside them. It
    /// also starts watching the root, so the figures follow the disk from
    /// then on.
    func measureDisk() {
        measurement?.cancel()
        guard let root else { return }
        stopped = false
        watchForChanges(in: root)
        let paths = repos.map(\.git.path)
        // Free space is cheap to read, so it doesn't wait for the walk.
        freeSpace = DiskUsage.freeSpace(at: root)
        measuringSize = true
        let id = UUID()
        measurementID = id
        measurement = Task {
            // Cancelled or not, unless another measurement has taken over.
            defer { if measurementID == id { measuringSize = false } }
            let walk = Task.detached(priority: .utility) {
                (DiskUsage.allocatedSizes(of: root, splitBy: paths), DiskUsage.freeSpace(at: root))
            }
            await forEach(repos) { repo in
                if let counts = await repo.git.refCounts() { repo.refCounts = counts }
            }
            let measured = await withTaskCancellationHandler {
                await walk.value
            } onCancel: {
                walk.cancel()
            }
            guard !Task.isCancelled, root == self.root else { return }
            if let sizes = measured.0 {
                directorySize = sizes.total
                for repo in repos {
                    if let size = sizes.subdirs[repo.git.path] { repo.size = size }
                }
            }
            freeSpace = measured.1
        }
    }

    private func watchForChanges(in root: URL) {
        guard watcher?.root != root else { return }
        watcher = DirectoryWatcher(directory: root) { [weak self] paths in
            Task { @MainActor in
                self?.diskChanged()
                self?.treeChanged(paths)
            }
        }.map { (root, $0) }
    }

    /// Something under the working directory changed, by Ghuppy's own
    /// git or by anything else. Walking the tree again is far dearer than
    /// reading the free space, so the sizes are measured again after the
    /// changes settle, and then at most every few seconds however busy the
    /// tree is. A bulk action measures once when it's done, so changes made
    /// meanwhile are left to that.
    private func diskChanged() {
        guard bulkActivity == nil else { return }
        sizesStale = true
        guard remeasuring == nil else { return }
        remeasuring = Task {
            while sizesStale && !Task.isCancelled {
                sizesStale = false
                measureDisk()
                await measurement?.value
                try? await Task.sleep(for: .seconds(5))
            }
            remeasuring = nil
        }
    }

    /// Some directories under the working directory changed. When one of
    /// them lies outside every repository and gained or lost a folder, or
    /// became a repository, a clone may have arrived or a repository gone,
    /// so the list is discovered again once such changes
    /// settle, and then at most every few seconds however busy the tree is.
    /// A refresh or a cleanup discovers on its own, so it goes first and
    /// this looks again after it. Changes inside the repositories, which are
    /// nearly all of them, cost nothing more than the check.
    private func treeChanged(_ paths: [String]) {
        guard let root, Discovery.couldChange(lastScan, under: root, paths: paths) else { return }
        reposStale = true
        lastTreeChange = .now
        guard rediscovering == nil else { return }
        let id = UUID()
        rediscoveringID = id
        rediscovering = Task {
            defer { if rediscoveringID == id { rediscovering = nil } }
            while reposStale && !Task.isCancelled {
                // A clone writes into a folder that isn't a checkout yet,
                // so its changes keep coming until it's done.
                let waiting = Date.now
                while !Task.isCancelled,
                      Date.now.timeIntervalSince(lastTreeChange) < Self.treeSettles,
                      Date.now.timeIntervalSince(waiting) < Self.treeSettlesAtMost {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                while scanning || refreshSlot.isRunning || bulkActivity != nil, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                guard !Task.isCancelled else { return }
                reposStale = false
                await rediscover()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Stops the discovery the tree's changes started, and forgets them,
    /// for a refresh that discovers anyway or Stop All.
    private func stopRediscovering() {
        rediscovering?.cancel()
        rediscovering = nil
        rediscoveringID = nil
        reposStale = false
    }

    /// Discovers the repositories again and loads the ones that are new,
    /// leaving the rest as they are.
    private func rediscover() async {
        let known = Set(repos.map(\.git.path))
        guard await discover() else { return }
        let added = repos.filter { !known.contains($0.git.path) }
        guard !added.isEmpty else { return }
        await forEach(added) { await self.reload($0) }
        // Their share of the working directory's size.
        if !Task.isCancelled { measureDisk() }
    }

    /// Re-reads the free space beside the working directory, for the status
    /// bar to call on a timer: files created or deleted by anything on the
    /// machine change it, not only by Ghuppy. It writes only when the
    /// figure moved, so an idle volume doesn't redraw the bar.
    func refreshFreeSpace() {
        guard let root, let free = DiskUsage.freeSpace(at: root), free != freeSpace else { return }
        freeSpace = free
    }

    /// Catches up with the pause on GitHub requests, for the status bar to
    /// call on a timer: it's shared by every tab, and any `gh` call can start it.
    func refreshRateLimit() async {
        let until = await PullRequests.pausedUntil()
        guard until != rateLimitedUntil else { return }
        if rateLimitedUntil == nil {
            append(nil, "GitHub rate limit reached, requests paused", isError: true)
        } else if until == nil {
            append(nil, "GitHub requests resumed")
        }
        rateLimitedUntil = until
    }

    /// Re-reads which repositories are under the root: ones added since the
    /// last look join the list, deleted ones leave it, and the rest keep
    /// their state. Returns false when there is no root, another discovery
    /// is already running, or the calling task was cancelled.
    @discardableResult
    func discover() async -> Bool {
        guard let root, !scanning else { return false }
        scanning = true
        defer { scanning = false }

        let scan = await Discovery.scan(under: root, knownMain: Set(repos.map(\.git.path)))
        let paths = scan.repositories
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard !Task.isCancelled, root == self.root else { return false }
        lastScan = scan
        let hadList = !repos.isEmpty
        let existing = Dictionary(uniqueKeysWithValues: repos.map { ($0.git.path, $0) })
        let updated = paths.map { path in
            existing[path] ?? RepoState(path: path, name: label(for: path, under: root))
        }
        if hadList {
            let kept = Set(paths)
            for repo in updated where existing[repo.git.path] == nil {
                append(repo.name, "new repository")
            }
            for repo in repos where !kept.contains(repo.git.path) {
                append(repo.name, "repository no longer there, removed from the list")
            }
        }
        repos = updated
        return true
    }

    private func label(for path: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.path != rootPath else { return root.lastPathComponent }
        return path.path.hasPrefix(rootPath + "/") ? String(path.path.dropFirst(rootPath.count + 1)) : path.path
    }

    func refreshLocal(_ repo: RepoState) async {
        if repo.github == nil {
            repo.github = await repo.git.gitHubRepo()
        }
        let status = await repo.git.status()
        // A git that was terminated reports an empty status.
        guard !Task.isCancelled else { return }
        repo.status = status
    }

    /// Reloads a repository's status and pull requests, for a refresh.
    private func reload(_ repo: RepoState) async {
        repo.refreshes += 1
        defer { repo.refreshes -= 1 }
        await refreshLocal(repo)
        await refreshPRs(repo)
    }

    /// Reloads a repository's pull requests. A failure is logged when it
    /// starts, not on every reload that goes on to meet it. GitHub is asked
    /// where they stand first, so `watchPullRequests` catches whatever
    /// changes after the reload, unless the caller has just asked and passes
    /// what it saw as `look`: the reload is then one `watchPullRequests`
    /// started, and nothing shows it loading.
    func refreshPRs(_ repo: RepoState, after look: PullRequestChanges.Look? = nil) async {
        // A git that was terminated leaves `github` nil, which isn't a
        // repository that has lost its remote.
        guard !Task.isCancelled else { return }
        guard let github = repo.github else {
            repo.pullRequests = []
            repo.mergedPullRequests = []
            repo.prError = nil
            repo.prsLoaded = true
            return
        }
        let quiet = look != nil
        if !quiet { repo.loadingPRs = true }
        defer { if !quiet { repo.loadingPRs = false } }
        // Whether it changed doesn't matter: this reload is what's shown.
        let seen = if let look { look } else { try? await PullRequestChanges.shared.look(github, cwd: repo.git.path) }
        // Whether a reload cut short is left for `watchPullRequests` to try
        // again, by not remembering what the look saw.
        var retry = false
        do {
            var prs = try await PullRequests.open(in: github, cwd: repo.git.path)
            do {
                let extras = try await PullRequests.extras(in: github, cwd: repo.git.path)
                prs = PullRequests.applying(queue: extras.queue, awaitingApproval: extras.awaitingApproval, to: prs)
                repo.mergedPullRequests = extras.merged
                repo.extrasError = nil
            } catch let error where !(error is RateLimitError || error is CancellationError) {
                if repo.extrasError != error.localizedDescription {
                    append(repo.name, error.localizedDescription, isError: true)
                }
                repo.extrasError = error.localizedDescription
            }
            repo.pullRequests = prs
            repo.prsLoaded = true
            repo.prError = nil
        } catch is RateLimitError {
            // The status bar says so, once for every repository, and what's
            // on screen stays until a reload gets through.
            retry = true
        } catch is CancellationError {
            // The refresh taking over reloads it.
            retry = true
        } catch {
            // Not retried: a failure that lasts would reload every time. It's
            // on the card, and Refresh tries again.
            if repo.prError != error.localizedDescription {
                append(repo.name, "pull requests: \(error.localizedDescription)", isError: true)
            }
            repo.prError = error.localizedDescription
        }
        if !retry, let seen { await PullRequestChanges.shared.remember(seen) }
    }

    // MARK: Actions

    /// Starts refreshing one repository, for Stop All to be able to stop. It
    /// does nothing while the repository is already being refreshed or
    /// cleaned up.
    func startRefresh(of repo: RepoState) {
        guard !repo.isRefreshing, repo.activity == nil else { return }
        track { await self.reload(repo) }
    }

    /// Starts `cleanupAll`, for Stop All to be able to stop.
    func startCleanupAll(includingUnpinned: Bool = false) {
        track { await self.cleanupAll(includingUnpinned: includingUnpinned) }
    }

    /// Starts cleaning up one repository, for Stop All to be able to stop.
    func startCleanup(of repo: RepoState) {
        let dryRun = dryRun
        track { await self.cleanup(repo, dryRun: dryRun) }
    }

    private func track(_ work: @escaping @MainActor () async -> Void) {
        stopped = false
        let id = UUID()
        cleanups[id] = Task {
            await work()
            cleanups[id] = nil
        }
    }

    /// Stops everything running on the tab. Git and gh are terminated, and a
    /// cancelled task can't start them again, so a cleanup deletes nothing
    /// more from here on. What it already deleted stays deleted.
    func stopAll() {
        guard isRefreshing || measuringSize || !cleanups.isEmpty || changeCheck != nil else { return }
        refreshSlot.cancel()
        changeCheck?.cancel()
        cleanups.values.forEach { $0.cancel() }
        measurement?.cancel()
        remeasuring?.cancel()
        stopRediscovering()
        stopped = true
        append(nil, "Stopped")
    }

    /// Cleans up the repositories in scope, or every one of them. Dry run is
    /// read once, here: switching it mid-run doesn't change what the
    /// repositories still to come get.
    private func cleanupAll(includingUnpinned: Bool = false) async {
        guard bulkActivity == nil else { return }
        let dryRun = dryRun
        bulkActivity = dryRun ? "Ghuppying (dry run)…" : "Ghuppying…"
        defer { bulkActivity = nil }
        // Let a discovery already in flight (the first one, on opening the
        // tab) finish, then look again so the list is current.
        while scanning, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        freedByCleanupAll = 0
        pulledByCleanupAll = 0
        await discover()
        await forEach(includingUnpinned ? orderedRepos : scopedRepos) { await self.cleanup($0, dryRun: dryRun) }
        guard !Task.isCancelled else { return }
        append(nil, dryRun ? "Ghuppied ’em all! (dry run, nothing deleted or pulled)"
                           : "Ghuppied ’em all! Pulled \(GitRepo.commits(pulledByCleanupAll)), "
                               + "freed \(Self.bytes(freedByCleanupAll))")
        measureDisk()
    }

    private func cleanup(_ repo: RepoState, dryRun: Bool) async {
        await perform(dryRun ? "Ghuppying (dry run)…" : "Ghuppying…", on: repo) {
            let outcome = try await Cleanup(repo: repo.git, dryRun: dryRun).run(log: self.logger(for: repo))
            if dryRun { return "Ghuppied! (dry run)" }
            self.pulledByCleanupAll += outcome.pulled
            self.freedByCleanupAll += outcome.freed
            let freed = Self.bytes(outcome.freed)
            // Cleanup all sums them up, so only the repositories that freed something get a line.
            if outcome.freed > 0 || self.bulkActivity == nil { self.append(repo.name, "freed \(freed)") }
            if let failure = outcome.pullFailure { throw failure }
            return outcome.pulled == 0 ? "Ghuppied! Freed \(freed)"
                                       : "Ghuppied! Pulled \(GitRepo.commits(outcome.pulled)), freed \(freed)"
        }
        await refreshPRs(repo)
        // A bulk action measures once, when it's done. The whole working
        // directory is walked again rather than just this repository: its
        // nested repositories and removed worktrees count elsewhere. A
        // stopped cleanup starts nothing more.
        if bulkActivity == nil, !Task.isCancelled { measureDisk() }
    }

    /// Runs `body`, which returns the text to show when it succeeds.
    private func perform(_ activity: String, on repo: RepoState,
                         _ body: () async throws -> String) async {
        guard repo.activity == nil else { return }
        repo.activity = activity
        defer { repo.activity = nil }
        do {
            repo.result = (try await body(), false)
        } catch where Task.isCancelled {
            // A git that was terminated fails with nothing worth reporting.
            repo.result = ("Stopped", false)
        } catch {
            repo.result = (error.localizedDescription, true)
            append(repo.name, error.localizedDescription, isError: true)
        }
        await refreshLocal(repo)
    }

    // MARK: Helpers

    static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }

    private func logger(for repo: RepoState) -> Logger {
        let name = repo.name
        return { [weak self] line in
            self?.append(name, line, isError: line.hasPrefix("!") || line.contains(" ! "))
        }
    }

    func append(_ repo: String?, _ text: String, isError: Bool = false) {
        log.append(LogLine(repo: repo, text: text, isError: isError))
        if log.count > 5000 { log.removeFirst(log.count - 5000) }
    }

    func clearLog() { log.removeAll() }

    /// Runs `body` for each repository, a few at a time: enough to overlap
    /// network round-trips without starting a hundred `git fetch`es at once.
    /// Cancelling the calling task starts no more of them.
    private func forEach(_ items: [RepoState], _ body: @escaping @MainActor (RepoState) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            var iterator = items.makeIterator()
            for _ in 0..<Self.concurrency {
                guard !Task.isCancelled, let item = iterator.next() else { break }
                group.addTask { await body(item) }
            }
            while await group.next() != nil {
                if !Task.isCancelled, let item = iterator.next() {
                    group.addTask { await body(item) }
                }
            }
        }
    }
}
