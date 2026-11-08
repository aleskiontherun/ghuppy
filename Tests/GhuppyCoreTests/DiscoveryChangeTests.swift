import Foundation
import Testing
@testable import GhuppyCore

struct DiscoveryChangeTests {
    private let root = URL(fileURLWithPath: "/Users/me/github")
    private var scan: Discovery.Scan {
        Discovery.Scan(
            repositories: [root.appendingPathComponent("app"), root.appendingPathComponent("group/lib")],
            excluded: [root.appendingPathComponent("group/lib-wt")]
        )
    }

    private func couldChange(_ paths: String..., scan: Discovery.Scan? = nil) -> Bool {
        Discovery.couldChange(scan ?? self.scan, under: root, paths: paths)
    }

    @Test func changesInsideACheckoutDontCount() {
        #expect(!couldChange("/Users/me/github/app/", "/Users/me/github/app/.git/objects/ab/"))
        #expect(!couldChange("/Users/me/github/group/lib/Sources/"))
        #expect(!couldChange("/Users/me/github/group/lib-wt/.build/debug/"))
    }

    @Test func changesBesideTheCheckoutsDo() {
        // A clone or a deleted repository at the top, or in a group.
        #expect(couldChange("/Users/me/github/"))
        #expect(couldChange("/Users/me/github/group/"))
        // A clone filling a folder that isn't a checkout yet.
        #expect(couldChange("/Users/me/github/app/.git/", "/Users/me/github/new/"))
    }

    @Test func aCloneStillFetchingCounts() {
        // Git writes nothing but the new `.git` until the fetch is done.
        #expect(couldChange("/Users/me/github/new/.git/objects/pack/"))
        #expect(!couldChange("/Users/me/github/app/.git/objects/pack/"))
        // A root that becomes a repository changes what the walk skips.
        #expect(couldChange("/Users/me/github/.git/"))
    }

    @Test func aCheckoutsNameAsAPrefixIsNotInsideIt() {
        #expect(couldChange("/Users/me/github/app-two/"))
    }

    @Test func skippedAndTooDeepDirectoriesDontCount() {
        #expect(!couldChange("/Users/me/github/web/node_modules/left-pad/"))
        #expect(!couldChange("/Users/me/github/a/b/c/d/e/f/"))
        #expect(couldChange("/Users/me/github/a/b/c/d/e/"))
    }

    @Test func changesOutsideTheRootDont() {
        #expect(!couldChange("/Users/me/", "/Users/me/githubber/"))
        #expect(!couldChange())
    }

    @Test func aRootRepositoryIsNotABoundary() {
        let scan = Discovery.Scan(
            repositories: [root, root.appendingPathComponent("sibling")],
            excluded: [root.appendingPathComponent(".claude/worktrees")]
        )
        #expect(couldChange("/Users/me/github/", scan: scan))
        #expect(couldChange("/Users/me/github/new/", scan: scan))
        #expect(!couldChange("/Users/me/github/.git/refs/", scan: scan))
        #expect(!couldChange("/Users/me/github/.claude/worktrees/x/.build/", scan: scan))
        #expect(!couldChange("/Users/me/github/sibling/src/", scan: scan))
    }

    @Test func thePrivatePrefixFSEventsAddsIsDropped() {
        #expect(!couldChange("/private/Users/me/github/app/src/"))
        #expect(couldChange("/private/Users/me/github/new/"))
    }
}
