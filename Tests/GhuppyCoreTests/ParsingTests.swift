import Foundation
import Testing
@testable import GhuppyCore

@Suite struct GitHubRepoParsing {
    @Test(arguments: [
        "git@github.com:octo/hello.git",
        "git@github.com:octo/hello",
        "ssh://git@github.com/octo/hello.git",
        "ssh://git@github.com:22/octo/hello.git",
        "https://github.com/octo/hello.git",
        "https://github.com/octo/hello/",
        "https://user@github.com/octo/hello",
        "github-work:octo/hello.git",
    ])
    func parses(_ remote: String) {
        #expect(GitHubRepo(remoteURL: remote) == GitHubRepo(owner: "octo", name: "hello"))
    }

    @Test(arguments: [
        "git@gitlab.com:octo/hello.git",
        "/srv/git/hello.git",
        "https://github.com/octo",
    ])
    func rejects(_ remote: String) {
        #expect(GitHubRepo(remoteURL: remote) == nil)
    }
}

@Suite struct PullRequestDecoding {
    func pr(rollup: String, awaitingApproval: Bool = false, extra: String = "") throws -> PullRequest {
        let json = """
        [{"number": 7, "title": "Add thing", "url": "https://github.com/octo/hello/pull/7",
          "isDraft": false, "author": {"login": "octo"}, "headRefName": "feature/thing",
          "reviewDecision": "APPROVED", "mergeable": "CONFLICTING",
          "updatedAt": "2026-10-29T12:00:00Z", "statusCheckRollup": \(rollup) \(extra)}]
        """
        return try #require(PullRequests.applying(
            queue: [:], awaitingApproval: awaitingApproval ? [7] : [], to: PullRequests.decode(json)).first)
    }

    @Test func fields() throws {
        let pr = try pr(rollup: "[]")
        #expect(pr.number == 7)
        #expect(pr.author?.login == "octo")
        #expect(pr.review == .approved)
        #expect(pr.hasConflicts)
        #expect(pr.checks == .none)
        #expect(pr.mergeQueue == nil)
    }

    @Test func readyToMerge() throws {
        func ready(
            _ rollup: String, review: String, mergeable: String = "MERGEABLE", draft: Bool = false,
            awaitingApproval: Set<Int> = []
        ) throws -> Bool {
            let json = """
            [{"number": 7, "title": "t", "url": "https://github.com/octo/hello/pull/7",
              "isDraft": \(draft), "author": null, "headRefName": "b",
              "reviewDecision": \(review), "mergeable": "\(mergeable)",
              "updatedAt": "2026-10-29T12:00:00Z", "statusCheckRollup": \(rollup)}]
            """
            return try #require(PullRequests.applying(
                queue: [:], awaitingApproval: awaitingApproval, to: PullRequests.decode(json)).first).isReadyToMerge
        }
        let ok = #"[{"__typename": "StatusContext", "state": "SUCCESS"}]"#
        let running = #"[{"__typename": "CheckRun", "status": "IN_PROGRESS", "conclusion": ""}]"#
        #expect(try ready(ok, review: #""APPROVED""#))
        #expect(try ready("[]", review: "null"))
        #expect(try !ready(ok, review: #""REVIEW_REQUIRED""#))
        #expect(try !ready(ok, review: #""CHANGES_REQUESTED""#))
        #expect(try !ready(running, review: #""APPROVED""#))
        #expect(try !ready(ok, review: #""APPROVED""#, mergeable: "CONFLICTING"))
        #expect(try !ready(ok, review: #""APPROVED""#, draft: true))
        #expect(try !ready(ok, review: #""APPROVED""#, awaitingApproval: [7]))
        #expect(try !ready("[]", review: "null", awaitingApproval: [7]))
    }

    @Test func notReadyWithoutTheApprovalLookup() throws {
        let json = """
        [{"number": 7, "title": "t", "url": "https://github.com/octo/hello/pull/7",
          "isDraft": false, "author": null, "headRefName": "b",
          "reviewDecision": "APPROVED", "mergeable": "MERGEABLE",
          "updatedAt": "2026-10-29T12:00:00Z", "statusCheckRollup": []}]
        """
        let pr = try #require(PullRequests.decode(json).first)
        #expect(!pr.isReadyToMerge)
        #expect(pr.checks == .none)
    }

    @Test func passing() throws {
        let pr = try pr(rollup: """
        [{"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SUCCESS"},
         {"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SKIPPED"},
         {"__typename": "StatusContext", "state": "SUCCESS"}]
        """)
        #expect(pr.checks == .passing)
    }

    @Test func pending() throws {
        let pr = try pr(rollup: """
        [{"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SUCCESS"},
         {"__typename": "CheckRun", "status": "IN_PROGRESS", "conclusion": ""}]
        """)
        #expect(pr.checks == .pending)
    }

    @Test func failingWinsOverPending() throws {
        let pr = try pr(rollup: """
        [{"__typename": "CheckRun", "status": "IN_PROGRESS", "conclusion": ""},
         {"__typename": "StatusContext", "state": "FAILURE"}]
        """)
        #expect(pr.checks == .failing)
    }

    @Test func aDeploymentWaitingForApprovalIsPending() throws {
        let pr = try pr(rollup: #"[{"__typename": "CheckRun", "status": "WAITING", "conclusion": ""}]"#)
        #expect(pr.checks == .pending)
    }

    @Test func aWorkflowAwaitingApprovalOutranksEverythingButAFailure() throws {
        let passing = #"[{"__typename": "StatusContext", "state": "SUCCESS"}]"#
        let running = #"[{"__typename": "CheckRun", "status": "IN_PROGRESS", "conclusion": ""}]"#
        let failing = #"[{"__typename": "StatusContext", "state": "FAILURE"}]"#
        #expect(try pr(rollup: "[]", awaitingApproval: true).checks == .awaitingApproval)
        #expect(try pr(rollup: passing, awaitingApproval: true).checks == .awaitingApproval)
        #expect(try pr(rollup: running, awaitingApproval: true).checks == .awaitingApproval)
        #expect(try pr(rollup: failing, awaitingApproval: true).checks == .failing)
    }
}

@Suite struct ExtrasDecoding {
    func merged(_ number: Int, at mergedAt: String, updated: String = "2026-11-01T00:00:00Z") -> String {
        """
        {"number": \(number), "title": "PR \(number)", "url": "https://github.com/octo/hello/pull/\(number)",
         "isDraft": false, "author": {"login": "octo"}, "headRefName": "branch-\(number)",
         "updatedAt": "\(updated)", "mergedAt": "\(mergedAt)"}
        """
    }

    func open(_ number: Int, queue: String = "null", suites: String = "[]") -> String {
        """
        {"number": \(number), "mergeQueueEntry": \(queue),
         "commits": {"nodes": [{"commit": {"checkSuites": {"nodes": \(suites)}}}]}}
        """
    }

    func extras(open: String = "", merged: [String] = []) throws -> PullRequests.Extras {
        try PullRequests.decodeExtras("""
        {"open": {"nodes": [\(open)]}, "merged": {"nodes": [\(merged.joined(separator: ","))]}}
        """)
    }

    @Test func queueEntriesByNumber() throws {
        let entries = try extras(open: [
            open(7, queue: #"{"position": 2, "state": "AWAITING_CHECKS"}"#),
            open(8),
            open(9, queue: #"{"position": 1, "state": "UNMERGEABLE"}"#),
        ].joined(separator: ",")).queue
        #expect(entries.count == 2)
        #expect(entries[7] == PullRequest.QueueEntry(position: 2, state: "AWAITING_CHECKS"))
        #expect(entries[8] == nil)
        #expect(entries[9]?.isUnmergeable == true)
        #expect(entries[7]?.isUnmergeable == false)
    }

    @Test func awaitingApprovalIsASuiteThatConcludedActionRequired() throws {
        let awaiting = try extras(open: [
            open(7, suites: #"[{"conclusion": "SUCCESS"}, {"conclusion": "ACTION_REQUIRED"}]"#),
            open(8, suites: #"[{"conclusion": "SUCCESS"}, {"conclusion": null}]"#),
            open(9),
            #"{"number": 10, "mergeQueueEntry": null, "commits": {"nodes": [{"commit": {"checkSuites": null}}]}}"#,
            #"{"number": 11, "mergeQueueEntry": null, "commits": {"nodes": []}}"#,
        ].joined(separator: ",")).awaitingApproval
        #expect(awaiting == [7])
    }

    @Test func mergedAreTheLastThreeByMergeTimeNotUpdateTime() throws {
        let merged = try extras(merged: [
            // Merged long ago, commented on since: first in update order.
            self.merged(1, at: "2026-01-01T00:00:00Z", updated: "2026-11-03T00:00:00Z"),
            self.merged(2, at: "2026-10-30T00:00:00Z"),
            self.merged(3, at: "2026-10-31T00:00:00Z"),
            self.merged(4, at: "2026-10-29T00:00:00Z"),
            self.merged(5, at: "2026-10-28T00:00:00Z"),
        ]).merged
        #expect(merged.map(\.number) == [3, 2, 4])
    }

    @Test func mergedFields() throws {
        let pr = try #require(extras(merged: [merged(1, at: "2026-10-30T00:00:00Z")]).merged.first)
        #expect(pr.mergedAt == ISO8601DateFormatter().date(from: "2026-10-30T00:00:00Z"))
        #expect(pr.checks == .none)
        #expect(pr.review == .none)
    }

    @Test func fewerMergedThanShown() throws {
        #expect(try extras(merged: [merged(1, at: "2026-10-30T00:00:00Z")]).merged.count == 1)
        #expect(try extras().merged.isEmpty)
    }
}

@Suite struct MergeQueueOrdering {
    func prs(_ numbers: [Int]) throws -> [PullRequest] {
        try PullRequests.decode("[" + numbers.map { number in
            """
            {"number": \(number), "title": "PR", "url": "https://github.com/octo/hello/pull/\(number)",
             "isDraft": false, "headRefName": "branch", "updatedAt": "2026-10-29T12:00:00Z"}
            """
        }.joined(separator: ",") + "]")
    }

    @Test func queuedGoLastInQueueOrder() throws {
        let ordered = PullRequests.applying(queue: [
            5: .init(position: 2, state: "QUEUED"),
            4: .init(position: 3, state: "QUEUED"),
            2: .init(position: 1, state: "AWAITING_CHECKS"),
        ], awaitingApproval: [], to: try prs([5, 4, 3, 2, 1]))
        #expect(ordered.map(\.number) == [3, 1, 2, 5, 4])
        #expect(ordered.map(\.mergeQueue?.position) == [nil, nil, 1, 2, 3])
    }

    @Test func nothingQueuedKeepsTheOrder() throws {
        #expect(PullRequests.applying(queue: [:], awaitingApproval: [], to: try prs([3, 2, 1])).map(\.number) == [3, 2, 1])
    }
}

@Suite struct AuthorFilter {
    func prs(_ logins: [String?]) throws -> [PullRequest] {
        try PullRequests.decode("[" + logins.enumerated().map { number, login in
            """
            {"number": \(number), "title": "PR", "url": "https://github.com/octo/hello/pull/\(number)",
             "isDraft": false, "author": \(login.map { "{\"login\": \"\($0)\"}" } ?? "null"),
             "headRefName": "branch", "updatedAt": "2026-10-29T12:00:00Z"}
            """
        }.joined(separator: ",") + "]")
    }

    @Test func aBotReadsTheSameFromGhAndGraphQL() throws {
        #expect(try prs(["app/dependabot", "dependabot"]).map(\.authorLogin) == ["dependabot", "dependabot"])
    }

    @Test func noLoginIsNoAuthor() throws {
        #expect(try prs([nil, ""]).map(\.authorLogin) == [nil, nil])
    }

    @Test func authorsAreUniqueAndAlphabetical() throws {
        let prs = try prs(["zoe", "Bob", "app/alice", nil, "zoe", "alice"])
        #expect(PullRequests.authors(of: prs) == ["alice", "Bob", "zoe"])
    }

    @Test func selectedAuthorStaysOnOfferWithNoPRsLeft() throws {
        #expect(PullRequests.authors(of: try prs(["zoe"]), selected: "bob") == ["bob", "zoe"])
        #expect(PullRequests.authors(of: try prs(["zoe"]), selected: "zoe") == ["zoe"])
        #expect(PullRequests.authors(of: [], selected: "bob") == ["bob"])
    }

    @Test func filterKeepsTheOrder() throws {
        let prs = try prs(["zoe", "bob", nil, "app/zoe"])
        #expect(PullRequests.filter(prs, author: "zoe").map(\.number) == [0, 3])
        #expect(PullRequests.filter(prs, author: nil).map(\.number) == [0, 1, 2, 3])
        #expect(PullRequests.filter(prs, author: "nobody").isEmpty)
    }
}
