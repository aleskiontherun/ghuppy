import Foundation

public struct PullRequest: Sendable, Identifiable, Decodable, Equatable {
    public struct Author: Sendable, Decodable, Equatable {
        public let login: String
    }

    /// One entry of `statusCheckRollup`: a `CheckRun` (Actions and other
    /// check suites) carries status/conclusion, a `StatusContext` (the older
    /// commit-status API) carries state.
    public struct Check: Sendable, Decodable, Equatable {
        public let status: String?
        public let conclusion: String?
        public let state: String?
    }

    public let number: Int
    public let title: String
    public let url: URL
    public let isDraft: Bool
    public let author: Author?
    public let headRefName: String
    public let reviewDecision: String?
    public let mergeable: String?
    /// GitHub's word on the merge button, which `mergeable` doesn't cover:
    /// `CLEAN`, `HAS_HOOKS`, `UNSTABLE`, `BEHIND`, `BLOCKED`, `DIRTY`, `DRAFT`
    /// or `UNKNOWN`. A merged PR has none.
    public let mergeStateStatus: String?
    public let updatedAt: Date
    /// When the PR was merged, nil while it's open.
    public let mergedAt: Date?
    public let statusCheckRollup: [Check]?
    /// The PR's place in its base branch's merge queue, nil when it isn't
    /// in one. `gh pr list` has no field for it, so
    /// `applying(queue:awaitingApproval:to:)` fills it in.
    public internal(set) var mergeQueue: QueueEntry?
    /// Whether a workflow on the PR's latest commit is waiting for someone to
    /// approve its run, as a first-time contributor's is. Such a run has no
    /// check runs yet, so `statusCheckRollup` leaves it out, and can even
    /// read as all passing. nil until `applying(queue:awaitingApproval:to:)`
    /// fills it in, and so when that lookup failed.
    public internal(set) var checksAwaitApproval: Bool?

    public struct QueueEntry: Sendable, Decodable, Equatable {
        /// 1 is the next to merge.
        public let position: Int
        /// `QUEUED`, `AWAITING_CHECKS`, `MERGEABLE`, `UNMERGEABLE` or `LOCKED`.
        public let state: String

        public var isUnmergeable: Bool { state == "UNMERGEABLE" }
    }

    public var id: Int { number }

    /// Who opened the PR, nil when GitHub no longer knows. A bot reads the
    /// same however the PR was loaded: `gh pr list` calls it `app/dependabot`
    /// where GraphQL says `dependabot`.
    public var authorLogin: String? {
        guard let login = author?.login, !login.isEmpty else { return nil }
        return login.hasPrefix("app/") ? String(login.dropFirst(4)) : login
    }

    public enum Checks: Sendable {
        case none, passing, pending, awaitingApproval, failing
    }

    /// A failure comes first. Then a wait for approval, ahead of running
    /// checks: those finish on their own, and it doesn't.
    public var checks: Checks {
        let rollup = statusCheckRollup ?? []
        var pending = false
        for check in rollup {
            switch check.result {
            case .failing: return .failing
            case .pending: pending = true
            default: break
            }
        }
        if checksAwaitApproval == true { return .awaitingApproval }
        guard !rollup.isEmpty else { return .none }
        return pending ? .pending : .passing
    }

    public enum Review: Sendable {
        case none, approved, changesRequested, required
    }

    public var review: Review {
        switch reviewDecision {
        case "APPROVED": .approved
        case "CHANGES_REQUESTED": .changesRequested
        case "REVIEW_REQUIRED": .required
        default: .none
        }
    }

    /// Whether any check is still going, even when `checks` has settled on a
    /// failure or a wait for approval.
    public var checksRunning: Bool {
        statusCheckRollup?.contains { $0.result == .pending } ?? false
    }

    public var hasConflicts: Bool { mergeable == "CONFLICTING" }

    /// The base branch has moved on and its rules want the branch up to date
    /// before it merges. The merge queue does that for a PR in it.
    public var needsUpdate: Bool { mergeStateStatus == "BEHIND" && mergeQueue == nil }

    /// Whether GitHub would merge the PR now. `UNSTABLE` is a merge it allows
    /// despite a check that isn't required.
    private var gitHubAllowsMerge: Bool {
        ["CLEAN", "HAS_HOOKS", "UNSTABLE"].contains(mergeStateStatus)
    }

    /// Open, out of draft, not yet in the merge queue, and nothing in the way:
    /// GitHub allows the merge, with no conflicts, no failing, running or
    /// unapproved checks, no review still wanted. Not knowing about the merge
    /// or about unapproved checks counts against it: a label saying nothing is
    /// in the way has to know that.
    public var isReadyToMerge: Bool {
        guard mergedAt == nil, !isDraft, mergeQueue == nil, !hasConflicts, gitHubAllowsMerge,
              checksAwaitApproval == false else { return false }
        switch (checks, review) {
        case (.passing, .approved), (.passing, .none), (.none, .approved), (.none, .none): return true
        default: return false
        }
    }

    /// GitHub won't merge the PR for a reason the checks don't show: a required
    /// check that never reported, say, or an unresolved conversation. A failure
    /// or a wait for approval shows in the checks icon, so neither counts.
    public var isBlocked: Bool {
        mergeStateStatus == "BLOCKED" && checks != .failing && checks != .awaitingApproval
    }

    public enum Label: Sendable, Equatable {
        case merged, queued(QueueEntry), draft, conflicts, changesRequested, update, reviewRequired
        case checksRunning, ready, approved, blocked
    }

    /// The one label a PR shows: the most important that applies, nil when
    /// none does. A merged or queued PR is past everything below it, and a
    /// draft isn't asking for anything yet. Then what's holding the merge
    /// back, from the most work down to checks, which finish on their own.
    /// Good news comes next, as anything above it is what's left to do.
    /// Blocked only fills a row with nothing else to say.
    public var label: Label? {
        if mergedAt != nil { return .merged }
        if let mergeQueue { return .queued(mergeQueue) }
        if isDraft { return .draft }
        if hasConflicts { return .conflicts }
        if review == .changesRequested { return .changesRequested }
        if needsUpdate { return .update }
        if review == .required { return .reviewRequired }
        if checksRunning { return .checksRunning }
        if isReadyToMerge { return .ready }
        if review == .approved { return .approved }
        if isBlocked { return .blocked }
        return nil
    }
}

extension PullRequest.Check {
    var result: PullRequest.Checks {
        if let state {
            switch state {
            case "SUCCESS": return .passing
            case "PENDING", "EXPECTED": return .pending
            default: return .failing
            }
        }
        guard status == "COMPLETED" else { return .pending }
        switch conclusion {
        case "SUCCESS", "NEUTRAL", "SKIPPED": return .passing
        default: return .failing
        }
    }
}

public enum PullRequests {
    static let fields = [
        "number", "title", "url", "isDraft", "author", "headRefName",
        "reviewDecision", "mergeable", "mergeStateStatus", "updatedAt", "statusCheckRollup",
    ]

    /// Runs `gh`, at most a few at a time and retrying failures with backoff.
    /// GitHub's GraphQL endpoint (or a VPN in front of it) drops bursts of
    /// parallel requests with `HTTP 499` or `unexpected EOF`, and a sweep of
    /// a workspace is exactly such a burst.
    static func gh(_ args: [String], cwd: URL) async -> ShellResult {
        await ghGate.acquire()
        var result = await Shell.run(Shell.ghPath ?? "gh", args, cwd: cwd)
        for delay in [1, 3] where !result.ok {
            try? await Task.sleep(for: .seconds(delay))
            result = await Shell.run(Shell.ghPath ?? "gh", args, cwd: cwd)
        }
        await ghGate.release()
        return result
    }

    static let ghGate = AsyncGate(limit: 3)

    public static func open(in repo: GitHubRepo, cwd: URL) async throws -> [PullRequest] {
        let result = await gh([
            "pr", "list", "--repo", repo.slug, "--state", "open", "--limit", "100",
            "--json", fields.joined(separator: ","),
        ], cwd: cwd)
        guard result.ok else {
            throw ShellError(message: result.err.isEmpty ? "gh pr list failed" : result.err)
        }
        return try decode(result.stdout)
    }

    /// What `gh pr list` can't say about the open PRs, and the latest merged
    /// ones. Kept apart from `open` so a failed lookup costs only these, not
    /// the list.
    public struct Extras: Sendable, Equatable {
        /// The merge queue entries of the open PRs, by PR number.
        public let queue: [Int: PullRequest.QueueEntry]
        /// The numbers of the open PRs with a workflow waiting for approval.
        public let awaitingApproval: Set<Int>
        /// The last merged first.
        public let merged: [PullRequest]
    }

    /// How many merged PRs a repository shows.
    static let mergedShown = 3
    /// How many recently updated merged PRs are searched for those. GitHub
    /// can't order by merge time, but a PR is never updated before it's
    /// merged, so the latest merges are near the top of this order, behind
    /// only the older PRs that were touched since.
    static let mergedSearched = 30

    /// Asks for the same 100 open PRs `gh pr list` lists: the newest first.
    /// One query for both, as a repository's PRs are reloaded on a timer and
    /// every `gh` call counts against the GitHub rate limit.
    public static func extras(in repo: GitHubRepo, cwd: URL) async throws -> Extras {
        let query = """
        query($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) {
            open: pullRequests(states: OPEN, first: 100, orderBy: {field: CREATED_AT, direction: DESC}) {
              nodes {
                number
                mergeQueueEntry { position state }
                commits(last: 1) { nodes { commit { checkSuites(first: 100) { nodes { conclusion } } } } }
              }
            }
            merged: pullRequests(states: MERGED, first: \(mergedSearched), orderBy: {field: UPDATED_AT, direction: DESC}) {
              nodes { number title url isDraft author { login } headRefName updatedAt mergedAt }
            }
          }
        }
        """
        let result = await gh([
            "api", "graphql", "-f", "query=\(query)", "-f", "owner=\(repo.owner)", "-f", "name=\(repo.name)",
            "--jq", ".data.repository",
        ], cwd: cwd)
        guard result.ok else {
            throw ShellError(message: "merge queue, workflow approval and merged pull requests lookup failed: \(result.err)")
        }
        return try decodeExtras(result.stdout)
    }

    public static func decodeExtras(_ json: String) throws -> Extras {
        struct Connection<Node: Decodable>: Decodable {
            let nodes: [Node]
        }
        struct Suite: Decodable {
            let conclusion: String?
        }
        struct Commit: Decodable {
            let checkSuites: Connection<Suite>?
        }
        struct CommitNode: Decodable {
            let commit: Commit
        }
        struct OpenNode: Decodable {
            let number: Int
            let mergeQueueEntry: PullRequest.QueueEntry?
            let commits: Connection<CommitNode>

            /// A workflow waiting for approval is a suite that has already
            /// completed, with this conclusion and no check runs.
            var awaitsApproval: Bool {
                commits.nodes.contains { node in
                    node.commit.checkSuites?.nodes.contains { $0.conclusion == "ACTION_REQUIRED" } ?? false
                }
            }
        }
        struct Response: Decodable {
            let open: Connection<OpenNode>
            let merged: Connection<PullRequest>
        }
        let response = try decoder.decode(Response.self, from: Data(json.utf8))
        let queue = Dictionary(
            response.open.nodes.compactMap { node in node.mergeQueueEntry.map { (node.number, $0) } },
            uniquingKeysWith: { first, _ in first })
        let awaitingApproval = Set(response.open.nodes.filter(\.awaitsApproval).map(\.number))
        let merged = response.merged.nodes.sorted { ($0.mergedAt ?? .distantPast) > ($1.mergedAt ?? .distantPast) }
        return Extras(queue: queue, awaitingApproval: awaitingApproval, merged: Array(merged.prefix(mergedShown)))
    }

    /// `prs` with their merge queue entries and workflow approvals filled in,
    /// the ones ready to merge moved to the front, and the queued ones to the
    /// end, the next to merge first.
    public static func applying(
        queue: [Int: PullRequest.QueueEntry], awaitingApproval: Set<Int>, to prs: [PullRequest]
    ) -> [PullRequest] {
        var prs = prs
        for index in prs.indices {
            prs[index].mergeQueue = queue[prs[index].number]
            prs[index].checksAwaitApproval = awaitingApproval.contains(prs[index].number)
        }
        let queued = prs.filter { $0.mergeQueue != nil }
            .sorted { ($0.mergeQueue?.position ?? 0) < ($1.mergeQueue?.position ?? 0) }
        let unqueued = prs.filter { $0.mergeQueue == nil }
        return unqueued.filter(\.isReadyToMerge) + unqueued.filter { !$0.isReadyToMerge } + queued
    }

    /// The authors of `prs` and `selected`, in alphabetical order. `selected`
    /// is there for an author whose PRs have since gone from the list: a
    /// select can't show a choice it doesn't offer.
    public static func authors(of prs: [PullRequest], selected: String? = nil) -> [String] {
        Set(prs.compactMap(\.authorLogin) + [selected].compactMap { $0 })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The PRs `author` opened, or all of them when `author` is nil.
    public static func filter(_ prs: [PullRequest], author: String?) -> [PullRequest] {
        guard let author else { return prs }
        return prs.filter { $0.authorLogin == author }
    }

    public static func decode(_ json: String) throws -> [PullRequest] {
        try decoder.decode([PullRequest].self, from: Data(json.utf8))
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public enum BranchState: Sendable {
        case merged, open, none
    }

    /// Whether a branch's PR was merged, is still open, or never existed.
    /// An open PR wins over an older merged one for the same head: the branch
    /// is still in use.
    public static func state(ofBranch branch: String, in repo: GitHubRepo, cwd: URL) async throws -> BranchState {
        let result = await gh([
            "pr", "list", "--repo", repo.slug, "--head", branch, "--state", "all",
            "--json", "state",
        ], cwd: cwd)
        guard result.ok else {
            throw ShellError(message: "gh pr list for \(branch) failed: \(result.err)")
        }
        struct Entry: Decodable { let state: String }
        let states = try JSONDecoder().decode([Entry].self, from: Data(result.stdout.utf8)).map(\.state)
        if states.contains("OPEN") { return .open }
        if states.contains("MERGED") { return .merged }
        return .none
    }
}

/// A counting semaphore for async code.
actor AsyncGate {
    private let limit: Int
    private var inUse = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        if inUse < limit {
            inUse += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            inUse -= 1
        } else {
            // Hand the slot straight to the next waiter.
            waiters.removeFirst().resume()
        }
    }
}
