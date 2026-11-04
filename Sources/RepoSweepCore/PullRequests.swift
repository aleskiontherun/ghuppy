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
    public let updatedAt: Date
    /// When the PR was merged, nil while it's open.
    public let mergedAt: Date?
    public let statusCheckRollup: [Check]?
    /// The PR's place in its base branch's merge queue, nil when it isn't
    /// in one. `gh pr list` has no field for it, so `applying(queue:to:)`
    /// fills it in.
    public internal(set) var mergeQueue: QueueEntry?

    public struct QueueEntry: Sendable, Decodable, Equatable {
        /// 1 is the next to merge.
        public let position: Int
        /// `QUEUED`, `AWAITING_CHECKS`, `MERGEABLE`, `UNMERGEABLE` or `LOCKED`.
        public let state: String

        public var isUnmergeable: Bool { state == "UNMERGEABLE" }
    }

    public var id: Int { number }

    public enum Checks: Sendable {
        case none, passing, pending, failing
    }

    public var checks: Checks {
        let rollup = statusCheckRollup ?? []
        guard !rollup.isEmpty else { return .none }
        var pending = false
        for check in rollup {
            switch check.result {
            case .failing: return .failing
            case .pending: pending = true
            default: break
            }
        }
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

    public var hasConflicts: Bool { mergeable == "CONFLICTING" }

    /// Open, out of draft, not yet in the merge queue, and nothing in the way:
    /// no conflicts, no failing or running checks, no review still wanted.
    public var isReadyToMerge: Bool {
        guard mergedAt == nil, !isDraft, mergeQueue == nil, !hasConflicts else { return false }
        switch (checks, review) {
        case (.passing, .approved), (.passing, .none), (.none, .approved), (.none, .none): return true
        default: return false
        }
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
        "reviewDecision", "mergeable", "updatedAt", "statusCheckRollup",
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
              nodes { number mergeQueueEntry { position state } }
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
            throw ShellError(message: "merge queue and merged pull requests lookup failed: \(result.err)")
        }
        return try decodeExtras(result.stdout)
    }

    public static func decodeExtras(_ json: String) throws -> Extras {
        struct Connection<Node: Decodable>: Decodable {
            let nodes: [Node]
        }
        struct OpenNode: Decodable {
            let number: Int
            let mergeQueueEntry: PullRequest.QueueEntry?
        }
        struct Response: Decodable {
            let open: Connection<OpenNode>
            let merged: Connection<PullRequest>
        }
        let response = try decoder.decode(Response.self, from: Data(json.utf8))
        let queue = Dictionary(
            response.open.nodes.compactMap { node in node.mergeQueueEntry.map { (node.number, $0) } },
            uniquingKeysWith: { first, _ in first })
        let merged = response.merged.nodes.sorted { ($0.mergedAt ?? .distantPast) > ($1.mergedAt ?? .distantPast) }
        return Extras(queue: queue, merged: Array(merged.prefix(mergedShown)))
    }

    /// `prs` with their merge queue entries filled in, and the queued ones
    /// moved to the end, the next to merge first.
    public static func applying(queue: [Int: PullRequest.QueueEntry], to prs: [PullRequest]) -> [PullRequest] {
        var prs = prs
        for index in prs.indices {
            prs[index].mergeQueue = queue[prs[index].number]
        }
        let queued = prs.filter { $0.mergeQueue != nil }
            .sorted { ($0.mergeQueue?.position ?? 0) < ($1.mergeQueue?.position ?? 0) }
        return prs.filter { $0.mergeQueue == nil } + queued
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
