import Foundation

/// Receives progress lines as an operation runs. Main-actor bound so the UI
/// can append to its log directly, and awaited so lines arrive in order.
public typealias Logger = @MainActor @Sendable (String) -> Void

public struct GitHubRepo: Sendable, Hashable, Codable {
    public let owner: String
    public let name: String

    public var slug: String { "\(owner)/\(name)" }
    public var url: URL { URL(string: "https://github.com/\(owner)/\(name)")! }

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    /// Parses the remote URL forms git accepts for a GitHub repository:
    /// `git@github.com:o/r.git`, `ssh://git@github.com/o/r`,
    /// `https://github.com/o/r.git`, and SSH host aliases such as
    /// `github-work:o/r` that people set up for multiple accounts.
    public init?(remoteURL raw: String) {
        var rest = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        if let schemeRange = rest.range(of: "://") {
            rest = String(rest[schemeRange.upperBound...])
            if let at = rest.firstIndex(of: "@"), at < (rest.firstIndex(of: "/") ?? rest.endIndex) {
                rest = String(rest[rest.index(after: at)...])
            }
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            host = String(rest[..<slash]).split(separator: ":").first.map(String.init) ?? ""
            rest = String(rest[rest.index(after: slash)...])
        } else if let colon = rest.firstIndex(of: ":") {
            var hostPart = String(rest[..<colon])
            if let at = hostPart.firstIndex(of: "@") {
                hostPart = String(hostPart[hostPart.index(after: at)...])
            }
            host = hostPart
            rest = String(rest[rest.index(after: colon)...])
        } else {
            return nil
        }
        guard host.lowercased().contains("github") else { return nil }

        if rest.hasSuffix("/") { rest.removeLast() }
        if rest.hasSuffix(".git") { rest.removeLast(4) }
        let parts = rest.split(separator: "/")
        guard parts.count == 2 else { return nil }
        self.init(owner: String(parts[0]), name: String(parts[1]))
    }
}

/// What `git status` says about a checkout, for the repository header.
public struct LocalStatus: Sendable, Equatable, Codable {
    public var branch: String?
    public var upstream: String?
    public var ahead = 0
    public var behind = 0
    public var dirty = false

    public init() {}
}

/// One entry of `git worktree list`.
struct Worktree: Sendable {
    var path: String
    var head: String?
    var branch: String?
    var detached = false
    var locked = false
    /// Git's own verdict that the directory is gone.
    var prunable = false
}

/// How many worktrees and branches a repository has, for its header.
public struct RefCounts: Sendable, Equatable, Codable {
    /// The linked worktrees still on disk, the checkout itself not counted.
    public var worktrees = 0
    public var localBranches = 0
    /// The remote-tracking branches of every remote, each remote's `HEAD`
    /// pointer not counted.
    public var remoteBranches = 0

    public init(worktrees: Int = 0, localBranches: Int = 0, remoteBranches: Int = 0) {
        self.worktrees = worktrees
        self.localBranches = localBranches
        self.remoteBranches = remoteBranches
    }
}

/// Git operations on one checkout. Every method is safe to call off the main
/// actor; the actual work happens in child processes.
public struct GitRepo: Sendable, Hashable {
    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    @discardableResult
    func git(_ args: String...) async -> ShellResult {
        await git(args)
    }

    @discardableResult
    func git(_ args: [String], stdin: String? = nil) async -> ShellResult {
        await Shell.run(Shell.gitPath ?? "git", args, cwd: path, stdin: stdin)
    }

    /// Like `git(_:)`, but a non-zero exit throws with git's own message.
    @discardableResult
    func gitChecked(_ args: String...) async throws -> String {
        let result = await git(args)
        guard result.ok else {
            throw ShellError(message: "git \(args.joined(separator: " ")) failed: \(result.err)")
        }
        return result.out
    }

    public func gitHubRepo() async -> GitHubRepo? {
        let result = await git("remote", "get-url", "origin")
        guard result.ok else { return nil }
        return GitHubRepo(remoteURL: result.out)
    }

    public func defaultBranch() async -> String {
        let result = await git("symbolic-ref", "--short", "refs/remotes/origin/HEAD")
        if result.ok, let slash = result.out.firstIndex(of: "/") {
            return String(result.out[result.out.index(after: slash)...])
        }
        return "main"
    }

    public func currentBranch() async -> String? {
        let result = await git("branch", "--show-current")
        return result.ok && !result.out.isEmpty ? result.out : nil
    }

    public func isDirty() async -> Bool {
        // Untracked files count: `git switch` and `reset` can clobber them too.
        !(await git("status", "--porcelain").out.isEmpty)
    }

    public func status() async -> LocalStatus {
        var status = LocalStatus()
        let result = await git("status", "--porcelain=v2", "--branch")
        guard result.ok else { return status }
        for line in result.stdout.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") {
                let head = String(line.dropFirst("# branch.head ".count))
                status.branch = head == "(detached)" ? nil : head
            } else if line.hasPrefix("# branch.upstream ") {
                status.upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                let parts = line.dropFirst("# branch.ab ".count).split(separator: " ")
                if parts.count == 2 {
                    status.ahead = Int(parts[0].dropFirst()) ?? 0
                    status.behind = Int(parts[1].dropFirst()) ?? 0
                }
            } else if !line.hasPrefix("#") {
                status.dirty = true
            }
        }
        return status
    }

    /// Every worktree registration except the main checkout, which
    /// `git worktree remove` refuses anyway, and the repo path itself.
    func linkedWorktrees() async throws -> [Worktree] {
        var trees: [Worktree] = []
        var current: Worktree?
        for line in try await gitChecked("worktree", "list", "--porcelain").split(
            separator: "\n", omittingEmptySubsequences: false
        ) {
            if line.isEmpty {
                if let tree = current { trees.append(tree) }
                current = nil
                continue
            }
            let parts = line.split(separator: " ", maxSplits: 1)
            let key = String(parts[0]), value = parts.count > 1 ? String(parts[1]) : ""
            switch key {
            case "worktree": current = Worktree(path: value)
            case "HEAD": current?.head = value
            case "branch": current?.branch = value.hasPrefix("refs/heads/") ? String(value.dropFirst(11)) : value
            case "detached": current?.detached = true
            case "locked": current?.locked = true
            case "prunable": current?.prunable = true
            default: break
            }
        }
        if let tree = current { trees.append(tree) }

        let resolved = { (path: String) in URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        var skip: Set<String> = [resolved(path.path)]
        if let main = trees.first { skip.insert(resolved(main.path)) }
        return trees.filter { !skip.contains(resolved($0.path)) }
    }

    /// Counts the repository's worktrees and branches, nil when git can't
    /// read them.
    public func refCounts() async -> RefCounts? {
        guard let trees = try? await linkedWorktrees() else { return nil }
        let refs = await git("for-each-ref", "--format=%(refname) %(symref)", "refs/heads", "refs/remotes")
        guard refs.ok else { return nil }
        var counts = RefCounts(worktrees: trees.filter { !$0.prunable }.count)
        for line in refs.stdout.split(separator: "\n") {
            // A symbolic ref, such as `origin/HEAD`, names a branch counted already.
            guard line.hasSuffix(" ") else { continue }
            if line.hasPrefix("refs/heads/") {
                counts.localBranches += 1
            } else {
                counts.remoteBranches += 1
            }
        }
        return counts
    }

    /// `git fetch --prune`, tried again when another git is writing the same
    /// remote-tracking refs. An IDE or another app fetching in the background
    /// -- most likely right after a merge, when everything fetches -- makes
    /// ours fail with "cannot lock ref": it found the ref locked, or moved
    /// between reading and writing it. Waiting for the other fetch to finish
    /// and fetching again is all it takes.
    /// `remote` names the remote to fetch, git's own choice when nil:
    /// the checked-out branch's remote, or `origin`.
    func fetchPrune(remote: String? = nil, log: Logger, attempts: Int = 3,
                    retryDelay: Duration = .seconds(1)) async throws {
        let args = ["fetch", "--prune"] + (remote.map { [$0] } ?? [])
        for attempt in 1...attempts {
            let fetch = await git(args)
            if fetch.ok { return }
            guard attempt < attempts, fetch.stderr.contains("cannot lock ref") else {
                throw ShellError(message: "git \(args.joined(separator: " ")) failed: \(fetch.err)")
            }
            await log("another git is updating \(remote ?? "origin")'s refs, fetching again")
            try await Task.sleep(for: retryDelay * attempt)
        }
    }

    /// "1 commit", "3 commits".
    public static func commits(_ count: Int) -> String {
        "\(count) commit\(count == 1 ? "" : "s")"
    }
}
