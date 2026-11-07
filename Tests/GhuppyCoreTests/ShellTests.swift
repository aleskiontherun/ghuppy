import Foundation
import Testing
@testable import GhuppyCore

struct ShellTests {
    private let cwd = FileManager.default.temporaryDirectory

    @Test func cancellingTerminatesTheProcess() async {
        let started = ContinuousClock.now
        let sleep = Task { await Shell.run("/bin/sleep", ["30"], cwd: cwd) }
        try? await Task.sleep(for: .milliseconds(200))
        sleep.cancel()
        let result = await sleep.value
        #expect(!result.ok)
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func aCancelledTaskStartsNoProcess() async throws {
        let marker = cwd.appendingPathComponent("ghuppy-shell-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let touch = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await Shell.run("/usr/bin/touch", [marker.path], cwd: cwd)
        }
        let result = await touch.value
        #expect(!result.ok)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    /// A process gone before its stdin is written must not raise SIGPIPE.
    @Test func survivesAProcessThatLeavesItsStdinUnread() async {
        let input = String(repeating: "x", count: 1 << 20)
        let result = await Shell.run("/usr/bin/true", [], cwd: cwd, stdin: input)
        #expect(result.ok)
    }

    @Test func aDiscoveryCancelledStopsWalking() async throws {
        let root = cwd.appendingPathComponent("ghuppy-shell-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("a/repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let walk = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await Discovery.repositories(under: root)
        }
        #expect(await walk.value.isEmpty)
    }
}
