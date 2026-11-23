import Foundation

/// The Markdown files under a working directory, for the Files view.
public enum MarkdownFiles {
    static let extensions: Set<String> = ["md", "markdown"]
    private static let concurrency = 6

    public static func isMarkdown(_ path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Every Markdown file under `root`, as paths relative to it, sorted.
    ///
    /// Inside each of `repositories`, the checkouts the tab lists, the files
    /// are the ones git lists, tracked or untracked but not ignored, so a
    /// repository's build output and vendored packages stay out. Outside them
    /// the walk skips hidden folders and the ones `Discovery` never enters,
    /// and stops at any checkout, which the list leaves out for a reason:
    /// linked worktrees, and the ones the root repository ignores.
    /// Cancelling the calling task ends the listing early, with only part
    /// of it.
    public static func list(under root: URL, repositories: [URL]) async -> [String] {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = root.path == "/" ? "/" : root.path + "/"
        let inside = repositories.filter { $0.path == root.path || $0.path.hasPrefix(prefix) }

        var found = inside.contains(where: { $0.path == root.path }) ? [] : walk(root)
        await withTaskGroup(of: [String].self) { group in
            var queue = inside.makeIterator()
            for _ in 0..<concurrency {
                guard let repo = queue.next() else { break }
                group.addTask { await tracked(in: repo) }
            }
            for await files in group {
                found += files
                if !Task.isCancelled, let repo = queue.next() {
                    group.addTask { await tracked(in: repo) }
                }
            }
        }
        return found
            .compactMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Whether a change to the contents of any of `paths`, directories as a
    /// `DirectoryWatcher` reports them, could add or remove a file `list`
    /// finds. One inside a `.git`, or inside a folder the walk never enters,
    /// such as `node_modules`, can't: nearly all of a build's or a fetch's.
    public static func couldChange(paths: [String]) -> Bool {
        paths.contains { path in
            !path.split(separator: "/").contains { Discovery.skippedNames.contains(String($0)) }
        }
    }

    /// The Markdown files outside every checkout, by absolute path.
    private static func walk(_ root: URL) -> [String] {
        var found: [String] = []
        var queue: [(URL, Int)] = [(root, 0)]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        while !queue.isEmpty, !Task.isCancelled {
            let (dir, depth) = queue.removeFirst()
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys, options: .skipsHiddenFiles
            ) else { continue }
            for entry in entries {
                guard let values = try? entry.resourceValues(forKeys: Set(keys)),
                      values.isSymbolicLink != true else { continue }
                if values.isDirectory == true {
                    guard depth + 1 < Discovery.maxDepth,
                          !Discovery.skippedNames.contains(entry.lastPathComponent),
                          !Discovery.isRepo(entry) else { continue }
                    queue.append((entry, depth + 1))
                } else if isMarkdown(entry.lastPathComponent) {
                    found.append(entry.standardizedFileURL.path)
                }
            }
        }
        return found
    }

    /// The Markdown files git lists in a checkout, by absolute path: the
    /// ones still on disk, so a file deleted but not yet committed is gone.
    private static func tracked(in repo: URL) async -> [String] {
        let result = await GitRepo(path: repo).git([
            "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--deduplicate",
            "--", ":(icase)*.md", ":(icase)*.markdown",
        ])
        guard result.ok else { return [] }
        let fileManager = FileManager.default
        return result.stdout.split(separator: "\0")
            // A checkout nested in this one, which git doesn't look inside.
            .filter { !$0.hasSuffix("/") }
            .map { repo.appendingPathComponent(String($0)).path }
            .filter { fileManager.fileExists(atPath: $0) }
    }

    /// The file to show while none has been chosen: the README at the top
    /// of the working directory, else the one nearest the top, else nil.
    public static func defaultFile(in paths: [String]) -> String? {
        paths
            .filter { isReadme(($0 as NSString).lastPathComponent) }
            .min { lhs, rhs in
                let depths = (lhs.split(separator: "/").count, rhs.split(separator: "/").count)
                return depths.0 != depths.1 ? depths.0 < depths.1
                    : lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
    }

    static func isReadme(_ name: String) -> Bool {
        (name as NSString).deletingPathExtension.lowercased() == "readme" && isMarkdown(name)
    }
}

/// The Files view's side pane: every folder holding a Markdown file, as deep
/// as it lies, each open unless it has been closed.
public enum MarkdownTree {
    public struct Row: Identifiable, Hashable, Sendable {
        public enum Kind: Sendable { case folder, file }

        public let kind: Kind
        /// Relative to the working directory: the file's, or the folder's.
        public let path: String
        /// What the row shows: a file's name, or a folder's, which goes on
        /// down through folders holding nothing but one other folder.
        public let name: String
        public let depth: Int

        public var id: String { kind == .folder ? path + "/" : path }
    }

    private final class Node {
        var files: [String] = []
        var folders: [String: Node] = [:]
    }

    /// The rows for `paths`, relative paths of files: in each folder its
    /// folders, then its files, each by name.
    public static func rows(for paths: [String]) -> [Row] {
        let top = Node()
        for path in paths {
            var components = path.split(separator: "/").map(String.init)
            guard let name = components.popLast() else { continue }
            var node = top
            for component in components {
                if let next = node.folders[component] {
                    node = next
                } else {
                    let next = Node()
                    node.folders[component] = next
                    node = next
                }
            }
            node.files.append(name)
        }
        var rows: [Row] = []
        append(top, at: "", depth: 0, to: &rows)
        return rows
    }

    /// `rows` without what lies inside the folders in `collapsed`, given
    /// by their rows' paths.
    public static func visible(_ rows: [Row], collapsed: Set<String>) -> [Row] {
        guard !collapsed.isEmpty else { return rows }
        var hiddenUnder: String?
        return rows.filter { row in
            if let hiddenUnder, row.path.hasPrefix(hiddenUnder) { return false }
            hiddenUnder = row.kind == .folder && collapsed.contains(row.path) ? row.path + "/" : nil
            return true
        }
    }

    private static func append(_ node: Node, at path: String, depth: Int, to rows: inout [Row]) {
        let byName: (String, String) -> Bool = { $0.localizedStandardCompare($1) == .orderedAscending }
        for name in node.folders.keys.sorted(by: byName) {
            var name = name
            var folder = node.folders[name]!
            while folder.files.isEmpty, folder.folders.count == 1, let (inner, next) = folder.folders.first {
                name += "/" + inner
                folder = next
            }
            rows.append(Row(kind: .folder, path: path + name, name: name, depth: depth))
            append(folder, at: path + name + "/", depth: depth + 1, to: &rows)
        }
        for file in node.files.sorted(by: byName) {
            rows.append(Row(kind: .file, path: path + file, name: file, depth: depth))
        }
    }
}
