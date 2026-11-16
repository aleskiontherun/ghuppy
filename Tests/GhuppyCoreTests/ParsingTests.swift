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
            _ rollup: String, review: String, mergeable: String = "MERGEABLE",
            mergeState: String = #""CLEAN""#, draft: Bool = false, awaitingApproval: Set<Int> = []
        ) throws -> Bool {
            let json = """
            [{"number": 7, "title": "t", "url": "https://github.com/octo/hello/pull/7",
              "isDraft": \(draft), "author": null, "headRefName": "b",
              "reviewDecision": \(review), "mergeable": "\(mergeable)", "mergeStateStatus": \(mergeState),
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
        #expect(try ready(ok, review: #""APPROVED""#, mergeState: #""HAS_HOOKS""#))
        #expect(try ready(ok, review: #""APPROVED""#, mergeState: #""UNSTABLE""#))
        #expect(try !ready(ok, review: #""APPROVED""#, mergeState: #""BEHIND""#))
        #expect(try !ready(ok, review: #""APPROVED""#, mergeState: #""BLOCKED""#))
        #expect(try !ready(ok, review: #""APPROVED""#, mergeState: #""UNKNOWN""#))
        #expect(try !ready(ok, review: #""APPROVED""#, mergeState: "null"))
    }

    @Test func aBranchBehindItsBaseNeedsAnUpdateUntilItIsQueued() throws {
        let behind = try pr(rollup: "[]", extra: #", "mergeStateStatus": "BEHIND""#)
        #expect(behind.needsUpdate)
        #expect(try !pr(rollup: "[]", extra: #", "mergeStateStatus": "CLEAN""#).needsUpdate)
        #expect(try !pr(rollup: "[]").needsUpdate)
        let queued = try #require(PullRequests.applying(
            queue: [7: .init(position: 1, state: "QUEUED")], awaitingApproval: [], to: [behind]).first)
        #expect(!queued.needsUpdate)
    }

    @Test func checksRunningSeesPastAFailureAndAnApprovalWait() throws {
        let running = #"{"__typename": "CheckRun", "status": "IN_PROGRESS", "conclusion": ""}"#
        let passed = #"{"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SUCCESS"}"#
        let failed = #"{"__typename": "StatusContext", "state": "FAILURE"}"#
        #expect(try pr(rollup: "[\(passed), \(running)]").checksRunning)
        #expect(try pr(rollup: "[\(failed), \(running)]").checksRunning)
        #expect(try pr(rollup: "[\(running)]", awaitingApproval: true).checksRunning)
        #expect(try !pr(rollup: "[\(passed), \(failed)]").checksRunning)
        #expect(try !pr(rollup: "[]").checksRunning)
    }

    @Test func notReadyWithoutTheApprovalLookup() throws {
        let json = """
        [{"number": 7, "title": "t", "url": "https://github.com/octo/hello/pull/7",
          "isDraft": false, "author": null, "headRefName": "b",
          "reviewDecision": "APPROVED", "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN",
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

@Suite struct PullRequestLabel {
    let passing = #"[{"__typename": "StatusContext", "state": "SUCCESS"}]"#
    let running = #"[{"__typename": "CheckRun", "status": "IN_PROGRESS", "conclusion": ""}]"#
    let failing = #"[{"__typename": "StatusContext", "state": "FAILURE"}]"#
    let approved = #""APPROVED""#
    let reviewRequired = #""REVIEW_REQUIRED""#
    let changesRequested = #""CHANGES_REQUESTED""#
    let entry = PullRequest.QueueEntry(position: 2, state: "QUEUED")

    /// `lookedUp` false is the extras lookup having failed, leaving `applying`
    /// uncalled.
    func label(
        _ rollup: String = "[]", review: String = "null", mergeState: String = "BLOCKED",
        mergeable: String = "MERGEABLE", draft: Bool = false, queued: Bool = false,
        mergedAt: String = "null", closedAt: String = "null", awaitingApproval: Bool = false,
        lookedUp: Bool = true
    ) throws -> PullRequest.Label {
        let json = """
        [{"number": 7, "title": "t", "url": "https://github.com/octo/hello/pull/7",
          "isDraft": \(draft), "author": null, "headRefName": "b",
          "reviewDecision": \(review), "mergeable": "\(mergeable)", "mergeStateStatus": "\(mergeState)",
          "updatedAt": "2026-10-29T12:00:00Z", "mergedAt": \(mergedAt),
          "closedAt": \(closedAt), "statusCheckRollup": \(rollup)}]
        """
        let prs = try PullRequests.decode(json)
        return try #require((lookedUp ? PullRequests.applying(
            queue: queued ? [7: entry] : [:], awaitingApproval: awaitingApproval ? [7] : [],
            to: prs) : prs).first).label
    }

    @Test func anUpdateOutranksRunningChecks() throws {
        #expect(try label(running, mergeState: "BEHIND") == .update)
    }

    /// Each line adds a condition to the ones before it, and the new one wins.
    /// A failure takes over from running checks, as it only counts once
    /// they've finished.
    @Test func eachLabelOutranksTheOnesBelowIt() throws {
        let merged = #""2026-10-30T12:00:00Z""#
        #expect(try label(mergeState: "UNKNOWN") == .unknown)
        #expect(try label(review: approved, mergeState: "UNKNOWN") == .approved)
        #expect(try label(review: approved) == .blocked)
        #expect(try label(running, review: approved) == .checksRunning)
        #expect(try label(running, review: reviewRequired) == .reviewRequired)
        #expect(try label(running, review: reviewRequired, awaitingApproval: true) == .checksAwaitApproval)
        #expect(try label(
            running, review: reviewRequired, mergeState: "BEHIND", awaitingApproval: true) == .update)
        #expect(try label(
            failing, review: reviewRequired, mergeState: "BEHIND", awaitingApproval: true) == .checksFailed)
        #expect(try label(
            failing, review: reviewRequired, mergeState: "BEHIND", mergeable: "CONFLICTING",
            awaitingApproval: true) == .conflicts)
        #expect(try label(
            failing, review: changesRequested, mergeState: "BEHIND", mergeable: "CONFLICTING",
            awaitingApproval: true) == .changesRequested)
        #expect(try label(
            failing, review: changesRequested, mergeState: "BEHIND", mergeable: "CONFLICTING",
            draft: true, awaitingApproval: true) == .draft)
        #expect(try label(
            failing, review: changesRequested, mergeState: "BEHIND", mergeable: "CONFLICTING",
            draft: true, queued: true, awaitingApproval: true) == .queued)
        #expect(try label(
            failing, review: changesRequested, mergeState: "BEHIND", mergeable: "CONFLICTING",
            draft: true, queued: true, closedAt: merged, awaitingApproval: true) == .closed)
        #expect(try label(
            failing, review: changesRequested, mergeState: "BEHIND", mergeable: "CONFLICTING",
            draft: true, queued: true, mergedAt: merged, closedAt: merged, awaitingApproval: true) == .merged)
    }

    @Test func readyOutranksApproved() throws {
        #expect(try label(passing, review: approved, mergeState: "CLEAN") == .ready)
        #expect(try label(passing, mergeState: "CLEAN") == .ready)
    }

    @Test func failedOnceEveryCheckHasFinished() throws {
        let failingAndRunning = #"""
        [{"__typename": "StatusContext", "state": "FAILURE"},
         {"__typename": "CheckRun", "status": "IN_PROGRESS", "conclusion": ""}]
        """#
        #expect(try label(failing) == .checksFailed)
        #expect(try label(failing, mergeState: "UNSTABLE") == .checksFailed)
        #expect(try label(failing, review: approved) == .checksFailed)
        #expect(try label(failingAndRunning) == .checksRunning)
    }

    @Test func approveWhileAWorkflowWaits() throws {
        #expect(try label(awaitingApproval: true) == .checksAwaitApproval)
        #expect(try label(review: approved, awaitingApproval: true) == .checksAwaitApproval)
        #expect(try label(passing, mergeState: "CLEAN", awaitingApproval: true) == .checksAwaitApproval)
    }

    @Test func blockedWhenTheChecksDoNotSayWhy() throws {
        #expect(try label() == .blocked)
        #expect(try label(passing) == .blocked)
        #expect(try label(passing, review: approved) == .blocked)
    }

    @Test func unknownUntilItIsKnown() throws {
        #expect(try label(passing, mergeState: "UNKNOWN") == .unknown)
        #expect(try label(passing, mergeState: "CLEAN", lookedUp: false) == .unknown)
    }
}

@Suite struct ExtrasDecoding {
    func merged(_ number: Int, at mergedAt: String?, closed closedAt: String? = nil,
                updated: String = "2026-11-01T00:00:00Z") -> String {
        """
        {"number": \(number), "title": "PR \(number)", "url": "https://github.com/octo/hello/pull/\(number)",
         "isDraft": false, "author": {"login": "octo"}, "headRefName": "branch-\(number)",
         "updatedAt": "\(updated)", "mergedAt": \(mergedAt.map { "\"\($0)\"" } ?? "null"),
         "closedAt": \((closedAt ?? mergedAt).map { "\"\($0)\"" } ?? "null")}
        """
    }

    func open(_ number: Int, queue: String = "null", suites: String = "[]") -> String {
        """
        {"number": \(number), "mergeQueueEntry": \(queue),
         "commits": {"nodes": [{"commit": {"checkSuites": {"nodes": \(suites)}}}]}}
        """
    }

    func issue(_ number: Int, closed closedAt: String? = nil, reason: String? = nil,
               updated: String = "2026-11-01T00:00:00Z") -> String {
        """
        {"number": \(number), "title": "Issue \(number)", "url": "https://github.com/octo/hello/issues/\(number)",
         "author": {"login": "octo"}, "updatedAt": "\(updated)",
         "closedAt": \(closedAt.map { "\"\($0)\"" } ?? "null"), "stateReason": \(reason.map { "\"\($0)\"" } ?? "null")}
        """
    }

    /// The whole response, as `gh api graphql` prints it. `lookups` are the
    /// pinned ones, by alias.
    func response(open: String = "", merged: [String] = [], issuesEnabled: Bool = true,
                  openIssues: [String] = [], closedIssues: [String] = [], lookups: [String: String] = [:],
                  errors: String? = nil) -> String {
        let pinned = lookups.map { #""\#($0.key)": \#($0.value)"# }.map { ", " + $0 }.joined()
        return """
        {"data": {"repository": {"open": {"nodes": [\(open)]}, "merged": {"nodes": [\(merged.joined(separator: ","))]},
         "hasIssuesEnabled": \(issuesEnabled),
         "openIssues": {"nodes": [\(openIssues.joined(separator: ","))]},
         "closedIssues": {"nodes": [\(closedIssues.joined(separator: ","))]}\(pinned)}}\(errors.map { #", "errors": \#($0)"# } ?? "")}
        """
    }

    func extras(open: String = "", merged: [String] = [], issuesEnabled: Bool = true,
                openIssues: [String] = [], closedIssues: [String] = [], lookups: [String: String] = [:],
                pinned: PullRequests.Pinned = PullRequests.Pinned()) throws -> PullRequests.Extras {
        try PullRequests.decodeExtras(response(
            open: open, merged: merged, issuesEnabled: issuesEnabled, openIssues: openIssues,
            closedIssues: closedIssues, lookups: lookups), pinned: pinned)
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

    @Test func openIssuesKeepTheirOrder() throws {
        let issues = try extras(openIssues: [issue(9), issue(4), issue(7)]).openIssues
        #expect(issues.map(\.number) == [9, 4, 7])
        #expect(issues.map(\.label) == [.open, .open, .open])
        #expect(issues[0].authorLogin == "octo")
        #expect(issues[0].url == URL(string: "https://github.com/octo/hello/issues/9"))
    }

    @Test func closedIssuesAreTheLastThreeByCloseTimeNotUpdateTime() throws {
        let closed = try extras(closedIssues: [
            // Closed long ago, commented on since: first in update order.
            issue(1, closed: "2026-01-01T00:00:00Z", updated: "2026-11-03T00:00:00Z"),
            issue(2, closed: "2026-10-30T00:00:00Z"),
            issue(3, closed: "2026-10-31T00:00:00Z"),
            issue(4, closed: "2026-10-29T00:00:00Z"),
            issue(5, closed: "2026-10-28T00:00:00Z"),
        ]).closedIssues
        #expect(closed.map(\.number) == [3, 2, 4])
        #expect(closed[0].closedAt == ISO8601DateFormatter().date(from: "2026-10-31T00:00:00Z"))
    }

    @Test func issuesTurnedOff() throws {
        #expect(try extras(issuesEnabled: false).issuesEnabled == false)
        #expect(try extras().issuesEnabled)
    }

    /// The last 3 merged are 3 not pinned, and the pinned ones come along
    /// however long ago they merged, closed without merging too, in order.
    @Test func pinnedMergedStayAlongWithTheLastThreeOthers() throws {
        let merged = try extras(
            merged: [
                self.merged(2, at: "2026-10-30T00:00:00Z"),
                self.merged(3, at: "2026-10-31T00:00:00Z"),
                self.merged(4, at: "2026-10-29T00:00:00Z"),
                self.merged(5, at: "2026-10-28T00:00:00Z"),
                self.merged(6, at: "2026-10-27T00:00:00Z"),
            ],
            lookups: [
                "pinnedPR3": self.merged(3, at: "2026-10-31T00:00:00Z"),
                "pinnedPR1": self.merged(1, at: "2026-01-01T00:00:00Z"),
                "pinnedPR9": self.merged(9, at: nil, closed: "2026-10-29T12:00:00Z"),
            ],
            pinned: PullRequests.Pinned(pullRequests: [1, 3, 9])
        ).merged
        #expect(merged.map(\.number) == [3, 2, 9, 4, 5, 1])
        #expect(merged.map(\.label) == [.merged, .merged, .closed, .merged, .merged, .merged])
    }

    /// A pinned one still open is in the open list, and a pinned one that's
    /// gone is left out.
    @Test func pinnedOpenOrGoneAreNotAmongTheMerged() throws {
        let extras = try extras(
            merged: [merged(2, at: "2026-10-30T00:00:00Z")],
            lookups: [
                "pinnedPR7": #"{"number": 7, "title": "PR 7", "url": "https://github.com/octo/hello/pull/7", "isDraft": false, "author": null, "headRefName": "b", "updatedAt": "2026-11-01T00:00:00Z", "mergedAt": null, "closedAt": null}"#,
                "pinnedPR8": "null",
                "pinnedIssue4": issue(4),
                "pinnedIssue5": "null",
            ],
            pinned: PullRequests.Pinned(pullRequests: [7, 8], issues: [4, 5]))
        #expect(extras.merged.map(\.number) == [2])
        #expect(extras.closedIssues.isEmpty)
    }

    @Test func pinnedClosedIssuesStayAlongWithTheLastThreeOthers() throws {
        let closed = try extras(
            closedIssues: [
                issue(2, closed: "2026-10-30T00:00:00Z"),
                issue(3, closed: "2026-10-31T00:00:00Z"),
                issue(4, closed: "2026-10-29T00:00:00Z"),
                issue(5, closed: "2026-10-28T00:00:00Z"),
            ],
            lookups: ["pinnedIssue1": issue(1, closed: "2026-01-01T00:00:00Z", reason: "NOT_PLANNED"),
                      "pinnedIssue3": issue(3, closed: "2026-10-31T00:00:00Z")],
            pinned: PullRequests.Pinned(issues: [1, 3])
        ).closedIssues
        #expect(closed.map(\.number) == [3, 2, 4, 5, 1])
        #expect(closed.last?.label == .notPlanned)
    }

    /// `gh` fails when any lookup does, printing the whole response.
    func failed(_ stdout: String) -> ShellResult {
        ShellResult(status: 1, stdout: stdout, stderr: "gh: Could not resolve to an Issue with the number of 5.")
    }

    func notFound(_ alias: String) -> String {
        #"{"type": "NOT_FOUND", "path": ["repository", "\#(alias)"], "message": "Could not resolve"}"#
    }

    @Test func aPinnedLookupNotFoundStillAnswers() throws {
        let stdout = response(lookups: ["pinnedIssue5": "null", "pinnedPR8": "null"],
                              errors: "[\(notFound("pinnedIssue5")), \(notFound("pinnedPR8"))]")
        #expect(PullRequests.answered(failed(stdout)))
        #expect(try PullRequests.decodeExtras(stdout, pinned: PullRequests.Pinned(pullRequests: [8], issues: [5]))
            .issuesEnabled)
    }

    @Test(arguments: [
        // Something else not found.
        #"{"data": {"repository": null}, "errors": [{"type": "NOT_FOUND", "path": ["repository"]}]}"#,
        // A pinned lookup failing for another reason.
        #"{"data": {"repository": {"pinnedPR8": null}}, "errors": [{"type": "FORBIDDEN", "path": ["repository", "pinnedPR8"]}]}"#,
        // A rate limit.
        #"{"data": null, "errors": [{"type": "RATE_LIMITED", "message": "API rate limit exceeded"}]}"#,
        // No response at all.
        "",
    ])
    func otherFailuresDoNotAnswer(_ stdout: String) {
        #expect(!PullRequests.answered(failed(stdout)))
    }
}

@Suite struct IssueLabels {
    func label(closed: Bool, reason: String?) throws -> GhuppyCore.Issue.Label {
        let json = """
        [{"number": 1, "title": "t", "url": "https://github.com/octo/hello/issues/1", "author": null,
          "updatedAt": "2026-11-01T00:00:00Z", "closedAt": \(closed ? #""2026-11-01T00:00:00Z""# : "null"),
          "stateReason": \(reason.map { "\"\($0)\"" } ?? "null")}]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try #require(decoder.decode([GhuppyCore.Issue].self, from: Data(json.utf8)).first).label
    }

    @Test func openUntilClosed() throws {
        #expect(try label(closed: false, reason: nil) == .open)
        // Reopened since it was last closed.
        #expect(try label(closed: false, reason: "REOPENED") == .open)
    }

    @Test func closedForItsReason() throws {
        #expect(try label(closed: true, reason: "COMPLETED") == .closed)
        #expect(try label(closed: true, reason: nil) == .closed)
        #expect(try label(closed: true, reason: "NOT_PLANNED") == .notPlanned)
        #expect(try label(closed: true, reason: "DUPLICATE") == .duplicate)
    }
}

@Suite struct MergeQueueOrdering {
    func prs(_ numbers: [Int], ready: Set<Int> = []) throws -> [PullRequest] {
        try PullRequests.decode("[" + numbers.map { number in
            """
            {"number": \(number), "title": "PR", "url": "https://github.com/octo/hello/pull/\(number)",
             "isDraft": false, "headRefName": "branch", "updatedAt": "2026-10-29T12:00:00Z",
             "mergeStateStatus": \(ready.contains(number) ? #""CLEAN""# : "null")}
            """
        }.joined(separator: ",") + "]")
    }

    @Test func queuedGoLastTheNextToMergeLast() throws {
        let ordered = PullRequests.applying(queue: [
            5: .init(position: 2, state: "QUEUED"),
            4: .init(position: 3, state: "QUEUED"),
            2: .init(position: 1, state: "AWAITING_CHECKS"),
        ], awaitingApproval: [], to: try prs([5, 4, 3, 2, 1]))
        #expect(ordered.map(\.number) == [3, 1, 4, 5, 2])
        #expect(ordered.map(\.mergeQueue?.position) == [nil, nil, 3, 2, 1])
    }

    @Test func readyGoFirstKeepingTheirOrder() throws {
        let ordered = PullRequests.applying(queue: [
            4: .init(position: 1, state: "QUEUED"),
        ], awaitingApproval: [], to: try prs([5, 4, 3, 2, 1], ready: [4, 3, 1]))
        #expect(ordered.map(\.number) == [3, 1, 5, 2, 4])
    }

    @Test func aWorkflowWaitingForApprovalIsNotPutFirst() throws {
        let ordered = PullRequests.applying(queue: [:], awaitingApproval: [1], to: try prs([2, 1], ready: [1]))
        #expect(ordered.map(\.number) == [2, 1])
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
        #expect(PullRequests.authors(of: [PullRequest](), selected: "bob") == ["bob"])
    }

    @Test func issuesAreFilteredTheSameWay() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let issues = try decoder.decode([GhuppyCore.Issue].self, from: Data("""
        [{"number": 1, "title": "t", "url": "https://github.com/octo/hello/issues/1",
          "author": {"login": "zoe"}, "updatedAt": "2026-11-01T00:00:00Z"},
         {"number": 2, "title": "t", "url": "https://github.com/octo/hello/issues/2",
          "author": {"login": "bob"}, "updatedAt": "2026-11-01T00:00:00Z"}]
        """.utf8))
        #expect(PullRequests.authors(of: issues) == ["bob", "zoe"])
        #expect(PullRequests.filter(issues, author: "zoe").map(\.number) == [1])
    }

    @Test func filterKeepsTheOrder() throws {
        let prs = try prs(["zoe", "bob", nil, "app/zoe"])
        #expect(PullRequests.filter(prs, author: "zoe").map(\.number) == [0, 3])
        #expect(PullRequests.filter(prs, author: nil).map(\.number) == [0, 1, 2, 3])
        #expect(PullRequests.filter(prs, author: "nobody").isEmpty)
    }
}
