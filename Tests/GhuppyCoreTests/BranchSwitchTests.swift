import Foundation
import Testing
@testable import GhuppyCore

@Suite(.serialized) struct BranchSwitchTests {
    private func head(_ f: Fixture) async throws -> String {
        try await f.git("branch", "--show-current")
    }

    private func sha(_ f: Fixture, _ ref: String) async throws -> String {
        try await f.git("rev-parse", ref)
    }

    @Test func switchesToABranchAndPullsIt() async throws {
        let f = try await Fixture()
        defer { f.cleanUp() }
        try await f.branch("feature", file: "feature")
        try await f.pushElsewhere("one", "two", to: "feature")

        let sink = await LogSink()
        let outcome = try await BranchSwitch(repo: f.repo).run(to: .local("feature"), log: sink.logger)

        #expect(outcome == BranchSwitch.Outcome(branch: "feature", switched: true, pulled: 2))
        #expect(try await head(f) == "feature")
        #expect(try await sha(f, "feature") == (try await sha(f, "origin/feature")))
    }

    @Test func pullsTheBranchAlreadyCheckedOut() async throws {
        let f = try await Fixture()
        defer { f.cleanUp() }
        try await f.pushElsewhere("one")

        let sink = await LogSink()
        let outcome = try await BranchSwitch(repo: f.repo).run(to: .local("main"), log: sink.logger)

        #expect(outcome == BranchSwitch.Outcome(branch: "main", switched: false, pulled: 1))
        #expect(try await sha(f, "main") == (try await sha(f, "origin/main")))
    }

    @Test func leavesABranchWithCommitsToPushAsItIs() async throws {
        let f = try await Fixture()
        defer { f.cleanUp() }
        try await f.branch("feature", file: "feature")
        try await f.git("switch", "-q", "feature")
        try await f.commit("unpushed", "x")
        try await f.git("switch", "-q", "main")
        let before = try await sha(f, "feature")

        let sink = await LogSink()
        let outcome = try await BranchSwitch(repo: f.repo).run(to: .local("feature"), log: sink.logger)

        #expect(outcome == BranchSwitch.Outcome(branch: "feature", switched: true, pulled: 0))
        #expect(try await sha(f, "feature") == before)
    }

    @Test func refusesABranchThatCantFastForward() async throws {
        let f = try await Fixture()
        defer { f.cleanUp() }
        try await f.branch("feature", file: "feature")
        try await f.git("switch", "-q", "feature")
        try await f.commit("mine", "x")
        try await f.git("switch", "-q", "main")
        try await f.pushElsewhere("theirs", to: "feature")
        let before = try await sha(f, "feature")

        let sink = await LogSink()
        await #expect(throws: ShellError.self) {
            try await BranchSwitch(repo: f.repo).run(to: .local("feature"), log: sink.logger)
        }
        // The checkout didn't move.
        #expect(try await head(f) == "main")
        #expect(try await sha(f, "feature") == before)
    }

    @Test func refusesWhileTrackedFilesHaveChanges() async throws {
        let f = try await Fixture()
        defer { f.cleanUp() }
        try await f.branch("feature", file: "feature")
        try await f.pushElsewhere("one")
        try "changed".write(to: f.clone.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        let sink = await LogSink()

        await #expect(throws: ShellError.self) {
            try await BranchSwitch(repo: f.repo).run(to: .local("feature"), log: sink.logger)
        }
        #expect(try await head(f) == "main")

        // Nor is the branch checked out pulled under them.
        let before = try await sha(f, "main")
        await #expect(throws: ShellError.self) {
            try await BranchSwitch(repo: f.repo).run(to: .local("main"), log: sink.logger)
        }
        #expect(try await sha(f, "main") == before)
    }

    @Test func untrackedFilesDontStandInTheWay() async throws {
        let f = try await Fixture()
        defer { f.cleanUp() }
        try await f.branch("feature", file: "feature")
        try await f.pushElsewhere("one", to: "feature")
        try "scratch".write(to: f.clone.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let sink = await LogSink()
        let outcome = try await BranchSwitch(repo: f.repo).run(to: .local("feature"), log: sink.logger)

        #expect(outcome == BranchSwitch.Outcome(branch: "feature", switched: true, pulled: 1))
        #expect(FileManager.default.fileExists(atPath: f.clone.appendingPathComponent("notes.txt").path))
    }

    @Test func leavesTheCheckoutWhereItWasWhenAnUntrackedFileIsInTheWay() async throws {
        let f = try await Fixture()
        defer { f.cleanUp() }
        try await f.branch("feature", file: "feature")
        // The pull would bring in `incoming`, which is untracked here.
        try await f.pushElsewhere("incoming", to: "feature")
        try "mine".write(to: f.clone.appendingPathComponent("incoming"), atomically: true, encoding: .utf8)

        let sink = await LogSink()
        await #expect(throws: ShellError.self) {
            try await BranchSwitch(repo: f.repo).run(to: .local("feature"), log: sink.logger)
        }
        #expect(try await head(f) == "main")
        #expect(try String(contentsOf: f.clone.appendingPathComponent("incoming"), encoding: .utf8) == "mine")
        // Fast-forwarded all the same, which needs no working tree.
        #expect(try await sha(f, "feature") == (try await sha(f, "origin/feature")))
    }

    @Test func refusesABranchCheckedOutInAnotherWorktree() async throws {
        let f = try await Fixture()
        defer { f.cleanUp() }
        try await f.branch("feature", file: "feature")
        try await f.pushElsewhere("one", to: "feature")
        try await f.git("worktree", "add", "-q", f.dir.appendingPathComponent("tree").path, "feature")
        let before = try await sha(f, "feature")

        let sink = await LogSink()
        await #expect(throws: ShellError.self) {
            try await BranchSwitch(repo: f.repo).run(to: .local("feature"), log: sink.logger)
        }
        #expect(try await head(f) == "main")
        #expect(try await sha(f, "feature") == before)
    }

    @Test func switchesToABranchThatTracksNothing() async throws {
        let f = try await Fixture()
        defer { f.cleanUp() }
        try await f.git("switch", "-q", "-c", "local-only")
        try await f.commit("local", "x")
        try await f.git("switch", "-q", "main")

        let sink = await LogSink()
        let outcome = try await BranchSwitch(repo: f.repo).run(to: .local("local-only"), log: sink.logger)

        #expect(outcome == BranchSwitch.Outcome(branch: "local-only", switched: true, pulled: 0))
        #expect(await sink.lines.contains("local-only tracks no branch, nothing to pull"))
    }

    @Test func switchesToABranchWhoseUpstreamIsGone() async throws {
        let f = try await Fixture()
        defer { f.cleanUp() }
        try await f.branch("feature", file: "feature")
        try await f.deleteRemote("feature")
        // Still there locally, as another clone's delete leaves it.
        try await f.git("update-ref", "refs/remotes/origin/feature", "feature")

        let sink = await LogSink()
        let outcome = try await BranchSwitch(repo: f.repo).run(to: .local("feature"), log: sink.logger)

        #expect(outcome == BranchSwitch.Outcome(branch: "feature", switched: true, pulled: 0))
        #expect(await sink.lines.contains("origin/feature is gone, feature has nothing to pull"))
    }

    @Test func createsABranchForARemoteOne() async throws {
        let f = try await Fixture()
        defer { f.cleanUp() }
        let other = f.dir.appendingPathComponent("other")
        try await f.sh(f.dir, "clone", "-q", f.origin.path, other.path)
        try await f.sh(other, "switch", "-q", "-c", "theirs/x")
        try "x".write(to: other.appendingPathComponent("x"), atomically: true, encoding: .utf8)
        try await f.sh(other, "add", "x")
        try await f.sh(other, "-c", "user.email=t@e.com", "-c", "user.name=T", "commit", "-q", "-m", "x")
        try await f.sh(other, "push", "-q", "origin", "theirs/x")
        try await f.git("fetch", "-q")

        #expect(try #require(await f.repo.branches()).remote == ["origin/theirs/x"])

        let sink = await LogSink()
        let outcome = try await BranchSwitch(repo: f.repo).run(to: .remote("origin/theirs/x"), log: sink.logger)

        #expect(outcome == BranchSwitch.Outcome(branch: "theirs/x", switched: true, pulled: 0))
        #expect(try await head(f) == "theirs/x")
        #expect(try await f.git("rev-parse", "--abbrev-ref", "theirs/x@{upstream}") == "origin/theirs/x")
        #expect(try #require(await f.repo.branches()).remote.isEmpty)
    }

    @Test func refusesARemoteBranchWhoseNameIsTaken() async throws {
        let f = try await Fixture()
        defer { f.cleanUp() }
        try await f.branch("feature", file: "feature")
        try await f.git("branch", "--unset-upstream", "feature")

        // Not offered, as the local branch shares its name.
        #expect(try #require(await f.repo.branches()).remote.isEmpty)
        let sink = await LogSink()
        await #expect(throws: ShellError.self) {
            try await BranchSwitch(repo: f.repo).run(to: .remote("origin/feature"), log: sink.logger)
        }
        #expect(try await head(f) == "main")
    }

    @Test func listsTheBranches() async throws {
        let f = try await Fixture()
        defer { f.cleanUp() }
        try await f.branch("feature", file: "feature")
        try await f.git("branch", "local-only")
        try await f.git("branch", "elsewhere")
        let tree = f.dir.appendingPathComponent("tree")
        try await f.git("worktree", "add", "-q", tree.path, "elsewhere")

        let branches = try #require(await f.repo.branches())

        // Git names the worktree by its real path, `/private/var` for `/var`.
        let elsewhere = try #require(branches.local.first?.worktree)
        #expect(URL(fileURLWithPath: elsewhere).resolvingSymlinksInPath() == tree.resolvingSymlinksInPath())
        #expect(branches.local == [
            Branches.Local(name: "elsewhere", worktree: elsewhere),
            Branches.Local(name: "feature", upstream: "origin/feature"),
            Branches.Local(name: "local-only"),
            Branches.Local(name: "main", upstream: "origin/main"),
        ])
        #expect(branches.remote.isEmpty)
    }

    @Test func splitsRemoteRefs() {
        #expect(GitRepo.split(remoteRef: "origin/feature/x", remotes: ["origin"])! == ("origin", "feature/x"))
        #expect(GitRepo.split(remoteRef: "a/b/c", remotes: ["a", "a/b"])! == ("a/b", "c"))
        #expect(GitRepo.split(remoteRef: "upstream/x", remotes: ["origin"]) == nil)
        #expect(GitRepo.split(remoteRef: "origin/", remotes: ["origin"]) == nil)
    }
}
