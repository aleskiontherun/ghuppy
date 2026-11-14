import Foundation
import Testing
@testable import GhuppyCore

@Suite struct SnapshotSaving {
    func pullRequests() throws -> [PullRequest] {
        let json = """
        [{"number": 7, "title": "Add thing", "url": "https://github.com/octo/hello/pull/7",
          "isDraft": false, "author": {"login": "octo"}, "headRefName": "feature/thing",
          "reviewDecision": "APPROVED", "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN",
          "updatedAt": "2026-10-29T12:00:00Z",
          "statusCheckRollup": [{"status": "COMPLETED", "conclusion": "SUCCESS"}]},
         {"number": 8, "title": "Queued thing", "url": "https://github.com/octo/hello/pull/8",
          "isDraft": false, "author": null, "headRefName": "feature/queued",
          "reviewDecision": null, "mergeable": "MERGEABLE", "mergeStateStatus": "BLOCKED",
          "updatedAt": "2026-10-30T08:30:00Z", "statusCheckRollup": [{"state": "PENDING"}]}]
        """
        return PullRequests.applying(
            queue: [8: PullRequest.QueueEntry(position: 1, state: "QUEUED")], awaitingApproval: [],
            to: try PullRequests.decode(json))
    }

    func snapshot() throws -> WorkspaceSnapshot {
        var status = LocalStatus()
        status.branch = "main"
        status.upstream = "origin/main"
        status.behind = 2
        status.dirty = true
        let prs = try pullRequests()
        return WorkspaceSnapshot(
            root: URL(fileURLWithPath: "/work"),
            repos: [
                WorkspaceSnapshot.Repo(
                    path: URL(fileURLWithPath: "/work/hello"), name: "hello",
                    github: GitHubRepo(owner: "octo", name: "hello"), status: status,
                    branches: Branches(local: [Branches.Local(name: "main", upstream: "origin/main")],
                                       remote: ["origin/feature/x"]),
                    pullRequests: prs, mergedPullRequests: [], prsLoaded: true,
                    result: WorkspaceSnapshot.Result(text: "Ghuppied! Freed 2 MB", isError: false),
                    size: 4096, refCounts: RefCounts(worktrees: 1, localBranches: 3, remoteBranches: 5)),
                WorkspaceSnapshot.Repo(path: URL(fileURLWithPath: "/work/local"), name: "local"),
            ],
            directorySize: 1 << 30)
    }

    @Test func roundTrips() throws {
        let saved = [try snapshot()]
        #expect(try Snapshots.decode(Snapshots.encode(saved)) == saved)
    }

    /// The merge queue entries and workflow approvals the GraphQL lookup
    /// filled in come back, and so do the labels they decide.
    @Test func keepsWhatDecidesLabels() throws {
        let restored = try #require(Snapshots.decode(Snapshots.encode([snapshot()])).first)
        let prs = restored.repos[0].pullRequests
        #expect(prs.map(\.label) == [.ready, .queued])
        #expect(prs[1].mergeQueue?.position == 1)
        #expect(prs[0].checksAwaitApproval == false)
    }

    @Test func sameSnapshotsMakeSameBytes() throws {
        #expect(try Snapshots.encode([snapshot()]) == Snapshots.encode([snapshot()]))
    }

    @Test func passesOverAnotherVersion() throws {
        let json = #"{"version": 999, "workspaces": [{"what": "ever"}]}"#
        #expect(try Snapshots.decode(Data(json.utf8)).isEmpty)
    }

    @Test func rejectsAFileItCantRead() {
        #expect(throws: (any Error).self) { try Snapshots.decode(Data("not json".utf8)) }
    }

    @Test func savesAndLoads() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ghuppy-snapshots-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "nested/cards.json")
        #expect(try Snapshots.load(from: url).isEmpty)
        let saved = [try snapshot()]
        try Snapshots.save(Snapshots.encode(saved), to: url)
        #expect(try Snapshots.load(from: url) == saved)
        try Snapshots.save(Snapshots.encode([]), to: url)
        #expect(try Snapshots.load(from: url).isEmpty)
    }
}
