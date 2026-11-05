import Foundation

/// Deletes local branches whose work has actually landed and the worktrees
/// stranded behind them, then pulls the default branch.
///
/// `[gone]` only means the remote branch was deleted -- not that it was
/// merged: it could have been abandoned, or be mid-flight in a stacked PR.
/// Squash-merged branches never show up in `git branch --merged` either. So
/// each `[gone]` branch is checked against GitHub, and deleted only when a PR
/// for it is MERGED. A branch with an OPEN PR is kept. A branch with no PR at
/// all is deleted only if `<base>` already contains its commits or an
/// equivalent squashed patch, and reported for manual review otherwise.
///
/// The branch checked out in the main checkout is a candidate too, `[gone]`
/// or not: a merged PR doesn't always delete its remote branch. Without
/// `[gone]` it is deleted when `<base>` holds an equal squashed patch, or
/// holds its commits and its PR is MERGED -- a branch just cut from `<base>`
/// is in `<base>` as well -- and never while a PR for it is open.
///
/// When the branch to delete is the one checked out in the main checkout,
/// the checkout is first switched to `<base>` -- provided it has no local
/// changes, which the switch could clobber.
///
/// The pull comes last, and only ever into `<base>`: a checkout that ends up
/// on `<base>` is fast-forwarded to `origin/<base>`, and one left on a kept
/// branch stays exactly where it is.
///
/// Nothing is removed with `--force`: a worktree with uncommitted work, or a
/// locked one, is kept and named in the log, and so is its branch.
///
/// `run` returns what it pulled and the space freed on disk: the size of each
/// worktree it removed. Deleting a branch frees next to nothing until git
/// collects its objects, so branches aren't counted.
public struct Cleanup: Sendable {
    public typealias PRLookup = @Sendable (_ branch: String) async throws -> PullRequests.BranchState

    /// What a run did.
    public struct Outcome: Sendable {
        /// How many commits the pull brought into `<base>`.
        public var pulled = 0
        /// The space freed on disk.
        public var freed: Int64 = 0
        /// Why `<base>` couldn't be fast-forwarded. Handed back rather than
        /// thrown: the rest of the run is done by then, and what it freed
        /// still counts.
        public var pullFailure: ShellError?
    }

    let repo: GitRepo
    let dryRun: Bool
    let lookup: PRLookup

    public init(repo: GitRepo, dryRun: Bool, lookup: PRLookup? = nil) {
        self.repo = repo
        self.dryRun = dryRun
        if let lookup {
            self.lookup = lookup
        } else {
            self.lookup = { branch in
                guard let gh = await repo.gitHubRepo() else { return .none }
                return try await PullRequests.state(ofBranch: branch, in: gh, cwd: repo.path)
            }
        }
    }

    @discardableResult
    public func run(log: Logger) async throws -> Outcome {
        try await repo.fetchPrune(log: log)
        let prune = await repo.git(dryRun ? ["worktree", "prune", "-n", "-v"] : ["worktree", "prune", "-v"])
        for line in (prune.stdout + prune.stderr).split(separator: "\n") {
            await log(String(line))
        }

        let base = await repo.defaultBranch()
        let baseRef = await repo.git("rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(base)").ok
            ? "origin/\(base)" : base
        let trees = try await linkedWorktrees()

        let branches = try await cleanBranches(base: base, baseRef: baseRef, trees: trees, log: log)
        let freed = branches.freed + (await cleanDetachedWorktrees(baseRef: baseRef, trees: trees, log: log))
        var outcome = await pull(base: base, baseRef: baseRef, checkout: branches.checkout, log: log)
        outcome.freed = freed
        return outcome
    }

    // MARK: Branches

    func goneBranches(excluding base: String) async throws -> [String] {
        let out = try await repo.gitChecked(
            "for-each-ref", "refs/heads", "--format=%(refname:short)|%(upstream:track)"
        )
        return out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] != base, parts[1].contains("[gone]") else { return nil }
            return String(parts[0])
        }
    }

    enum Verdict {
        case delete(String)
        case keep(String)
    }

    func verdict(for branch: String, baseRef: String, log: Logger) async -> Verdict {
        do {
            switch try await lookup(branch) {
            case .merged: return .delete("PR merged")
            case .open: return .keep("PR still open")
            case .none: break
            }
        } catch {
            await log("! \(error.localizedDescription)")
            return .keep("couldn't check its PR")
        }
        if await repo.git("merge-base", "--is-ancestor", branch, baseRef).ok {
            return .delete("no PR, already in \(baseRef)")
        }
        if await isSquashMerged(branch, into: baseRef) {
            return .delete("no PR, an equal patch is in \(baseRef)")
        }
        return .keep("review manually: no PR, not merged into \(baseRef)")
    }

    /// The verdict for the checked-out branch when its remote branch is still
    /// there (or it never had one). Like `git-main`, it asks whether `<base>`
    /// holds the branch's content -- but a branch with no commits of its own,
    /// just cut from `<base>`, is in `<base>` too, so a branch `<base>` holds
    /// as is also needs a merged PR. An equal squashed patch needs none: a
    /// branch with nothing of its own never gets that far.
    func checkedOutVerdict(for branch: String, baseRef: String, log: Logger) async -> Verdict {
        let state: PullRequests.BranchState
        do {
            state = try await lookup(branch)
        } catch {
            await log("! \(error.localizedDescription)")
            return .keep("couldn't check its PR")
        }
        if state == .open { return .keep("PR still open") }
        if await repo.git("merge-base", "--is-ancestor", branch, baseRef).ok {
            // At `<base>` itself it has nothing on it yet, whatever an older
            // PR from a branch of the same name says.
            if await repo.git("rev-parse", branch).out == (await repo.git("rev-parse", baseRef).out) {
                return .keep("nothing on it yet, it sits at \(baseRef)")
            }
            if state == .merged { return .delete("PR merged, already in \(baseRef)") }
            return .keep("no merged PR, and nothing of its own that \(baseRef) lacks")
        }
        if await isSquashMerged(branch, into: baseRef) {
            return .delete("an equal patch is in \(baseRef)")
        }
        return .keep("not merged into \(baseRef)")
    }

    /// A squash merge rewrites the branch as one new commit, so none of the
    /// branch's own commits are in base's history. Ask about content instead:
    /// collapse the branch into one commit off the merge base and let
    /// `git cherry` say whether base already holds an equal patch.
    func isSquashMerged(_ branch: String, into baseRef: String) async -> Bool {
        let mergeBase = await repo.git("merge-base", baseRef, branch)
        guard mergeBase.ok else { return false }
        let squashed = await repo.git("commit-tree", "\(branch)^{tree}", "-p", mergeBase.out, "-m", "_")
        guard squashed.ok else { return false }
        return await repo.git("cherry", baseRef, squashed.out).out.hasPrefix("-")
    }

    /// Returns the space freed by the worktrees removed with their branches,
    /// and the branch the checkout is left on, nil when it's detached. A dry
    /// run answers with the branch a real run would leave it on.
    func cleanBranches(base: String, baseRef: String, trees: [Worktree],
                       log: Logger) async throws -> (freed: Int64, checkout: String?) {
        var candidates = try await goneBranches(excluding: base)
        if candidates.isEmpty { await log("no [gone] branches") }
        let current = await repo.currentBranch()
        // Checked out but not [gone]: judged by `checkedOutVerdict`.
        let liveCurrent = current.flatMap { $0 != base && !candidates.contains($0) ? $0 : nil }
        if let liveCurrent { candidates.append(liveCurrent) }
        let attached = Dictionary(trees.compactMap { tree in tree.branch.map { ($0, tree) } },
                                  uniquingKeysWith: { first, _ in first })

        var freed: Int64 = 0
        var checkout = current
        for branch in candidates {
            let verdict = branch == liveCurrent
                ? await checkedOutVerdict(for: branch, baseRef: baseRef, log: log)
                : await verdict(for: branch, baseRef: baseRef, log: log)
            guard case .delete(let reason) = verdict else {
                if case .keep(let reason) = verdict { await log("\(branch): keep (\(reason))") }
                continue
            }
            let checkedOut = branch == current
            await log("\(branch): delete (\(reason))\(checkedOut ? ", checked out here" : "")\(dryRun ? " [dry run]" : "")")

            if checkedOut {
                guard try await switchToBase(base, from: branch, log: log) else { continue }
                checkout = base
            }
            if dryRun { continue }
            if let tree = attached[branch] {
                guard let size = await remove(tree, reason: "branch deleted", log: log) else {
                    // git won't drop a branch a worktree still has checked out.
                    await log("  \(branch) kept too, its worktree still holds it")
                    continue
                }
                freed += size
            }
            try await repo.gitChecked("branch", "-D", branch)
            await log("  deleted \(branch)")
        }
        return (freed, checkout)
    }

    /// Leaves `branch` for `base`, the way `git-main` does. Returns false, and
    /// stays put, when the checkout has local changes; a dry run only looks
    /// for those.
    func switchToBase(_ base: String, from branch: String, log: Logger) async throws -> Bool {
        if await repo.isDirty() {
            await log("  \(branch) kept: the checkout has local changes, commit or stash them first")
            return false
        }
        if dryRun { return true }
        try await repo.gitChecked("switch", base)
        await log("  switched to \(base)")
        return true
    }

    // MARK: Pull

    /// Fast-forwards `base` to `origin/<base>`, which `run` has just fetched,
    /// when `base` is what `checkout` is on. Any other branch is left alone,
    /// however far behind its upstream: a kept branch is someone's work in
    /// progress. Fast-forward only, so a pull never invents a merge commit or
    /// drops local commits on `base` that were never pushed, in a repository
    /// nobody is looking at.
    func pull(base: String, baseRef: String, checkout: String?, log: Logger) async -> Outcome {
        guard let checkout else {
            await log("detached HEAD, nothing to pull")
            return Outcome()
        }
        guard checkout == base else {
            await log("\(checkout) is checked out, not \(base), nothing to pull")
            return Outcome()
        }
        guard baseRef != base else {
            await log("\(base) has no origin/\(base), nothing to pull")
            return Outcome()
        }

        // A branch with no commits yet has nothing to count from.
        let local = await repo.git("rev-parse", "--verify", "--quiet", "refs/heads/\(base)")
        let range = local.ok ? "\(local.out)..\(baseRef)" : baseRef
        let incoming = Int(await repo.git("rev-list", "--count", range).out) ?? 0
        guard incoming > 0 else {
            await log("\(base) is up to date")
            return Outcome()
        }
        if dryRun {
            // With commits of its own, `base` can't fast-forward: `incoming`
            // only counts origin's side.
            let canPull = local.ok ? (await repo.git("merge-base", "--is-ancestor", local.out, baseRef).ok) : true
            await log(canPull ? "would pull \(GitRepo.commits(incoming)) into \(base) [dry run]"
                              : "! \(base) can't fast-forward to \(baseRef) [dry run]")
            return Outcome()
        }

        let merge = await repo.git("merge", "--ff-only", baseRef)
        guard merge.ok else {
            return Outcome(pullFailure: ShellError(message: "\(base) can't fast-forward to \(baseRef): \(merge.err)"))
        }
        await log("pulled \(GitRepo.commits(incoming)) into \(base)")
        return Outcome(pulled: incoming)
    }

    // MARK: Worktrees

    struct Worktree: Sendable {
        var path: String
        var head: String?
        var branch: String?
        var detached = false
        var locked = false
    }

    /// Every worktree registration except the main checkout, which
    /// `git worktree remove` refuses anyway, and the repo path itself.
    func linkedWorktrees() async throws -> [Worktree] {
        var trees: [Worktree] = []
        var current: Worktree?
        for line in try await repo.gitChecked("worktree", "list", "--porcelain").split(
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
            default: break
            }
        }
        if let tree = current { trees.append(tree) }

        let resolved = { (path: String) in URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        var skip: Set<String> = [resolved(repo.path.path)]
        if let main = trees.first { skip.insert(resolved(main.path)) }
        return trees.filter { !skip.contains(resolved($0.path)) }
    }

    /// Removes `tree` and returns the space that freed, or nil when the
    /// worktree is kept.
    func remove(_ tree: Worktree, reason: String, log: Logger) async -> Int64? {
        let path = tree.path
        guard FileManager.default.fileExists(atPath: path) else { return 0 }
        if tree.locked {
            await log("  worktree kept: \(path) (locked)")
            return nil
        }
        if !(await Shell.run(Shell.gitPath ?? "git", ["status", "--porcelain"], cwd: URL(fileURLWithPath: path)).out.isEmpty) {
            await log("  worktree kept: \(path) (uncommitted work)")
            return nil
        }
        let size = DiskUsage.allocatedSize(of: URL(fileURLWithPath: path)) ?? 0
        let result = await repo.git("worktree", "remove", path)
        guard result.ok else {
            await log("  worktree kept: \(path) (\(result.err))")
            return nil
        }
        await log("  worktree removed: \(path) (\(reason))")
        return size
    }

    /// Worktrees whose branch is already gone, left detached. Detached at a
    /// commit already in base means the work shipped; detached anywhere else
    /// means unmerged work nobody tracks any more -- reported, never removed.
    /// Returns the space freed by the worktrees removed.
    func cleanDetachedWorktrees(baseRef: String, trees: [Worktree], log: Logger) async -> Int64 {
        var freed: Int64 = 0
        for tree in trees where tree.detached {
            guard FileManager.default.fileExists(atPath: tree.path) else { continue }
            let head = tree.head ?? ""
            let short = String(head.prefix(8))
            guard await repo.git("merge-base", "--is-ancestor", head, baseRef).ok else {
                await log("dangling worktree \(tree.path): review manually (detached at \(short), not in \(baseRef))")
                continue
            }
            await log("dangling worktree \(tree.path): remove (detached at \(short), already in \(baseRef))\(dryRun ? " [dry run]" : "")")
            if !dryRun {
                freed += await remove(tree, reason: "detached, already in \(baseRef)", log: log) ?? 0
            }
        }
        return freed
    }
}
