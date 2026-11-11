import Foundation

/// The branches a checkout can switch to, for the branch menu.
public struct Branches: Sendable, Equatable {
    public struct Local: Sendable, Equatable, Hashable {
        public var name: String
        /// The branch it tracks, `origin/foo`, nil when it tracks none.
        public var upstream: String?
        /// Another worktree that has it checked out: git won't check it out
        /// here as well.
        public var worktree: String?

        public init(name: String, upstream: String? = nil, worktree: String? = nil) {
            self.name = name
            self.upstream = upstream
            self.worktree = worktree
        }
    }

    /// Every local branch, in name order.
    public var local: [Local] = []
    /// The remote-tracking branches, `origin/foo`, that no local branch
    /// tracks or shares a name with, in name order. Switching to one creates
    /// the local branch.
    public var remote: [String] = []

    public init(local: [Local] = [], remote: [String] = []) {
        self.local = local
        self.remote = remote
    }
}

extension GitRepo {
    /// The names of the repository's remotes.
    func remotes() async -> [String] {
        await git("remote").stdout.split(separator: "\n").map(String.init)
    }

    /// Lists the branches to offer, nil when git can't read them.
    public func branches() async -> Branches? {
        let refs = await git(
            "for-each-ref", "--format=%(refname)%09%(upstream)%09%(worktreepath)%09%(symref)",
            "refs/heads", "refs/remotes"
        )
        guard refs.ok else { return nil }
        let here = path.resolvingSymlinksInPath().path
        var local: [Branches.Local] = []
        var remote: [String] = []
        var tracked: Set<String> = []
        for line in refs.stdout.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, fields[3].isEmpty else { continue }
            let (ref, upstream, worktree) = (fields[0], fields[1], fields[2])
            if let name = ref.dropPrefix("refs/heads/") {
                if !upstream.isEmpty { tracked.insert(upstream) }
                let elsewhere = !worktree.isEmpty
                    && URL(fileURLWithPath: worktree).resolvingSymlinksInPath().path != here
                local.append(Branches.Local(
                    name: name, upstream: upstream.isEmpty ? nil : Self.shortRef(upstream),
                    worktree: elsewhere ? worktree : nil
                ))
            } else if let name = ref.dropPrefix("refs/remotes/") {
                remote.append(name)
            }
        }
        let names = Set(local.map(\.name))
        let remotes = await remotes()
        remote.removeAll { ref in
            tracked.contains("refs/remotes/\(ref)")
                || Self.split(remoteRef: ref, remotes: remotes).map { names.contains($0.branch) } ?? true
        }
        return Branches(local: local, remote: remote)
    }

    /// `origin/feature/x` as remote `origin` and branch `feature/x`, the
    /// longest remote name that fits winning, as a remote's name can hold
    /// a slash too. Nil when no remote fits.
    static func split(remoteRef ref: String, remotes: [String]) -> (remote: String, branch: String)? {
        remotes.filter { ref.hasPrefix($0 + "/") && ref.count > $0.count + 1 }
            .max { $0.count < $1.count }
            .map { ($0, String(ref.dropFirst($0.count + 1))) }
    }

    /// `refs/remotes/origin/foo` as `origin/foo`, `refs/heads/main` as `main`.
    static func shortRef(_ ref: String) -> String {
        ref.dropPrefix("refs/remotes/") ?? ref.dropPrefix("refs/heads/") ?? ref
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

/// Switches a checkout to a branch and brings that branch up to date with
/// the one it tracks, fast-forward only.
///
/// The branch's remote is fetched first. A switch that fails leaves the
/// checkout where it was: a branch with commits of its own that its
/// upstream lacks, while its upstream has new ones too, can't fast-forward,
/// and changes to tracked files could be clobbered, or stand in the way of
/// the pull, so they have to be committed or stashed first. A branch to
/// switch to is fast-forwarded before the checkout moves, so the switch is
/// the one step that touches the working tree. Untracked files don't count:
/// git refuses to overwrite them, and refuses the switch, or the pull of
/// the branch already checked out, before changing anything. The branch
/// stays fast-forwarded then.
///
/// Switching to the branch already checked out just pulls it. A branch
/// that tracks nothing, or whose upstream is gone, is switched to and left
/// as it is. A remote-tracking branch with no local branch gets one,
/// tracking it.
public struct BranchSwitch: Sendable {
    public enum Target: Sendable, Hashable {
        /// A local branch, by name.
        case local(String)
        /// A remote-tracking branch, `origin/foo`, with no local branch of
        /// the same name yet.
        case remote(String)
    }

    /// What a run did.
    public struct Outcome: Sendable, Equatable {
        /// The branch checked out now.
        public var branch: String
        /// Whether the checkout moved to it.
        public var switched = false
        /// How many commits the pull brought in.
        public var pulled = 0
    }

    let repo: GitRepo

    public init(repo: GitRepo) {
        self.repo = repo
    }

    public func run(to target: Target, log: Logger) async throws -> Outcome {
        let current = await repo.currentBranch()
        let name: String
        /// The full name of the branch to pull from.
        var upstream: String?
        var remote: String?
        switch target {
        case .local(let branch):
            name = branch
            let refs = await repo.git(
                "for-each-ref", "--format=%(refname)%09%(upstream)%09%(upstream:remotename)%09%(worktreepath)",
                "refs/heads/\(branch)"
            )
            guard refs.ok else { throw ShellError(message: "git for-each-ref failed: \(refs.err)") }
            // The pattern matches the branches under `branch/` too. Not
            // trimmed: a branch that tracks nothing ends in empty fields.
            guard let fields = refs.stdout.split(separator: "\n")
                .map({ $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) })
                .first(where: { $0.first == "refs/heads/\(branch)" }), fields.count == 4 else {
                throw ShellError(message: "there is no branch \(branch)")
            }
            // Git wouldn't switch to it, and fast-forwarding it would pull
            // it under that worktree's feet.
            if !fields[3].isEmpty, branch != current {
                throw ShellError(message: "can't switch to \(branch): it's checked out at \(fields[3])")
            }
            upstream = fields[1].isEmpty ? nil : fields[1]
            // A branch tracking another local branch has the remote ".".
            remote = fields[2].isEmpty || fields[2] == "." ? nil : fields[2]
        case .remote(let ref):
            guard let parts = GitRepo.split(remoteRef: ref, remotes: await repo.remotes()) else {
                throw ShellError(message: "\(ref) is on no remote")
            }
            name = parts.branch
            if await repo.git("rev-parse", "--verify", "--quiet", "refs/heads/\(name)").ok {
                throw ShellError(message: "can't create \(name) to track \(ref): a branch \(name) already exists")
            }
            upstream = "refs/remotes/\(ref)"
            remote = parts.remote
        }

        let tracksNothing = upstream == nil
        if let remote {
            await log("fetching \(remote)")
            try await repo.fetchPrune(remote: remote, log: log)
        }
        // Gone with the fetch's prune, or never fetched.
        if let ref = upstream, !(await repo.git("rev-parse", "--verify", "--quiet", ref).ok) {
            if case .remote(let short) = target {
                throw ShellError(message: "\(short) is no longer on \(remote ?? "its remote")")
            }
            await log("\(GitRepo.shortRef(ref)) is gone, \(name) has nothing to pull")
            upstream = nil
        }

        var behind = 0
        if case .local = target, let ref = upstream {
            let counts = try await repo.gitChecked("rev-list", "--left-right", "--count", "refs/heads/\(name)...\(ref)")
                .split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            guard counts.count == 2 else { throw ShellError(message: "can't compare \(name) with \(GitRepo.shortRef(ref))") }
            let ahead = counts[0]
            behind = counts[1]
            if ahead > 0, behind > 0 {
                throw ShellError(message: "\(name) can't fast-forward to \(GitRepo.shortRef(ref)): it has "
                    + "\(GitRepo.commits(ahead)) of its own, and \(GitRepo.commits(behind)) to pull")
            }
            if ahead > 0 { await log("\(name) has \(GitRepo.commits(ahead)) to push") }
        }

        let switching = name != current
        if switching || behind > 0,
           !(await repo.git("status", "--porcelain", "--untracked-files=no").out.isEmpty) {
            throw ShellError(message: "can't \(switching ? "switch to" : "pull") \(name): "
                + "the checkout has local changes, commit or stash them first")
        }
        guard !Task.isCancelled else { throw CancellationError() }

        var outcome = Outcome(branch: name)
        if switching, behind > 0, let ref = upstream {
            // Only from the commit compared above: a branch moved since is
            // left alone.
            let old = try await repo.gitChecked("rev-parse", "refs/heads/\(name)")
            let new = try await repo.gitChecked("rev-parse", ref)
            try await repo.gitChecked("update-ref", "-m", "ghuppy: fast-forward to \(GitRepo.shortRef(ref))",
                                      "refs/heads/\(name)", new, old)
            await log("pulled \(GitRepo.commits(behind)) into \(name)")
            outcome.pulled = behind
        }
        if switching {
            switch target {
            case .local:
                try await repo.gitChecked("switch", "--no-guess", name)
                await log("switched to \(name)")
            case .remote(let ref):
                try await repo.gitChecked("switch", "--track", "--create", name, "refs/remotes/\(ref)")
                await log("switched to \(name), a new branch tracking \(ref)")
            }
            outcome.switched = true
        }

        guard let ref = upstream else {
            if tracksNothing { await log("\(name) tracks no branch, nothing to pull") }
            return outcome
        }
        guard behind > 0 else {
            await log("\(name) is up to date with \(GitRepo.shortRef(ref))")
            return outcome
        }
        // Pulled before the switch.
        if switching { return outcome }
        let merge = await repo.git("merge", "--ff-only", ref)
        guard merge.ok else {
            throw ShellError(message: "\(name) can't fast-forward to \(GitRepo.shortRef(ref)): \(merge.err)")
        }
        await log("pulled \(GitRepo.commits(behind)) into \(name)")
        outcome.pulled = behind
        return outcome
    }
}
