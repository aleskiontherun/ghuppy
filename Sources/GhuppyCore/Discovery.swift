import Foundation

public enum Discovery {
    /// Directories never worth descending into, whatever the root's
    /// `.gitignore` says.
    static let skippedNames: Set<String> = [".git", "node_modules", ".build", "DerivedData", ".Trash"]
    static let maxDepth = 6

    /// What a walk of a root found.
    public struct Scan: Sendable, Equatable {
        /// The checkouts, the root first if it is one, then by path.
        public var repositories: [URL]
        /// The directories the walk found and then left out without looking
        /// inside: the ones the root repository ignores, and linked worktrees.
        public var excluded: [URL]
        /// The subdirectories of each directory the walk looked inside, by
        /// path, which tells a folder gained or lost from a file saved in it.
        public var listed: [String: Set<String>]

        public init(repositories: [URL] = [], excluded: [URL] = [], listed: [String: Set<String>] = [:]) {
            self.repositories = repositories
            self.excluded = excluded
            self.listed = listed
        }
    }

    /// Every checkout under `root`: the root itself if it is one, plus each
    /// directory holding a `.git` below it.
    public static func repositories(under root: URL) async -> [URL] {
        await scan(under: root).repositories
    }

    /// Every checkout under `root`, and what the walk left out on the way.
    ///
    /// A checkout is a boundary the walk doesn't descend into, so a repo's
    /// submodules and vendored checkouts stay out. When the root is itself a
    /// repository, anything it ignores is skipped -- an umbrella checkout
    /// ignores its scratch areas and agent worktrees but deliberately not the
    /// sibling repos inside it. Linked worktrees found anyway are dropped:
    /// they belong to their main checkout, and its cleanup handles them.
    /// The checkouts in `knownMain` were found to be main checkouts before
    /// and aren't asked again, which saves a git per repository on a walk
    /// that only looks for what's new. Cancelling the calling task ends the
    /// walk early, with only part of the list.
    public static func scan(under root: URL, knownMain: Set<URL> = []) async -> Scan {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let rootRepo = isRepo(root) ? GitRepo(path: root) : nil

        var found: [URL] = rootRepo == nil ? [] : [root]
        var excluded: [URL] = []
        var listed: [String: Set<String>] = [:]
        var queue: [(URL, Int)] = [(root, 0)]
        while !queue.isEmpty, !Task.isCancelled {
            let (dir, depth) = queue.removeFirst()
            guard depth < maxDepth else { continue }
            var children = subdirectories(of: dir)
            listed[dir.path] = Set(children.map(\.lastPathComponent))
            if let rootRepo {
                let ignored = await ignoredPaths(children, in: rootRepo)
                excluded += children.filter { ignored.contains($0.path) }
                children.removeAll { ignored.contains($0.path) }
            }
            for child in children {
                if isRepo(child) {
                    found.append(child)
                } else {
                    queue.append((child, depth + 1))
                }
            }
        }

        // By path: the root sorts first, and a group's repos sit together.
        found.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        var result: [URL] = []
        for repo in found {
            if repo == root || knownMain.contains(repo) {
                result.append(repo)
            } else if await isLinkedWorktree(repo) {
                excluded.append(repo)
            } else {
                result.append(repo)
            }
        }
        return Scan(repositories: result, excluded: excluded, listed: listed)
    }

    /// Whether a change to the contents of any of `paths`, directories as
    /// a `DirectoryWatcher` reports them, could change what a walk of `root`
    /// finds, given what the last one found. Changes inside a checkout, or
    /// inside anything the walk skips or goes too deep to reach, can't: a
    /// clone, a deleted repository, a `git init` or a renamed folder all
    /// change a directory outside every checkout. So does a clone still
    /// fetching into the `.git` of a folder that isn't a checkout yet, which
    /// tells the clone isn't done. A checkout's own top level isn't watched
    /// for losing its `.git`, which edits there would drown out.
    ///
    /// A directory the walk looked inside only counts when it has become a
    /// checkout or its subdirectories aren't the ones it had then, so files
    /// saved beside the checkouts -- all over a root that is a repository
    /// itself -- don't count. That costs a directory listing for each such
    /// path; `subdirectories` and `isRepo` stand in for the disk in tests.
    public static func couldChange(_ last: Scan, under root: URL, paths: [String]) -> Bool {
        couldChange(last, under: root, paths: paths,
                    subdirectories: { Set(Discovery.subdirectories(of: $0).map(\.lastPathComponent)) },
                    isRepo: Discovery.isRepo)
    }

    static func couldChange(
        _ last: Scan, under root: URL, paths: [String],
        subdirectories: (URL) -> Set<String>, isRepo: (URL) -> Bool
    ) -> Bool {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let rootIsRepo = last.repositories.contains { $0.path == rootPath }
        let boundaries = (last.repositories + last.excluded).map(\.path).filter { $0 != rootPath }
        let skipped = skippedNames.subtracting([".git"])
        return paths.contains { raw in
            var path = raw
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            // FSEvents reports the real path, which `resolvingSymlinksInPath`
            // strips `/private` from.
            if !rootPath.hasPrefix("/private/"), path.hasPrefix("/private/") {
                path.removeFirst("/private".count)
            }
            let inside = path == rootPath ? [] : path.hasPrefix(rootPath + "/")
                ? path.dropFirst(rootPath.count + 1).split(separator: "/").map(String.init) : nil
            // Any other `.git` is a known checkout's, which is a boundary,
            // or one being cloned.
            guard let inside, inside.count < maxDepth, !inside.contains(where: skipped.contains),
                  !(rootIsRepo && inside.first == ".git") else { return false }
            guard !boundaries.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return false }
            guard let before = last.listed[path] else { return true }
            let dir = URL(fileURLWithPath: path)
            return (path != rootPath && isRepo(dir)) || subdirectories(dir) != before
        }
    }

    public static func isRepo(_ url: URL) -> Bool {
        // A worktree's `.git` is a file rather than a directory.
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    static func subdirectories(of dir: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys
        ) else { return [] }
        return entries
            .filter { url in
                guard !skippedNames.contains(url.lastPathComponent),
                      let values = try? url.resourceValues(forKeys: Set(keys)) else { return false }
                return values.isDirectory == true && values.isSymbolicLink != true
            }
            .map(\.standardizedFileURL)
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func ignoredPaths(_ paths: [URL], in repo: GitRepo) async -> Set<String> {
        guard !paths.isEmpty else { return [] }
        let root = repo.path.path + "/"
        let relative = paths.map { String($0.path.dropFirst(root.count)) }
        let result = await repo.git(["check-ignore", "--stdin"], stdin: relative.joined(separator: "\n") + "\n")
        // 0 = some path matched, 1 = none did, anything else is an error.
        guard result.status <= 1 else { return [] }
        return Set(result.stdout.split(separator: "\n").map { root + $0 })
    }

    static func isLinkedWorktree(_ url: URL) async -> Bool {
        let result = await GitRepo(path: url).git("rev-parse", "--path-format=absolute", "--git-common-dir")
        guard result.ok else { return false }
        let common = URL(fileURLWithPath: result.out).resolvingSymlinksInPath().path
        let own = url.appendingPathComponent(".git").resolvingSymlinksInPath().path
        return common != own
    }
}
