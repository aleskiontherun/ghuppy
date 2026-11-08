import Foundation
import Testing
@testable import GhuppyCore

struct DirectoryWatcherTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    private final class Paths: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        var value: [String] { lock.withLock { paths } }
        func add(_ more: [String]) { lock.withLock { paths += more } }
    }

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghuppy-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        return dir
    }

    /// Waits up to five seconds for `counter` to reach `count`.
    private func wait(for counter: Counter, toReach count: Int = 1) async -> Bool {
        for _ in 0..<50 {
            if counter.value >= count { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    @Test func reportsAFileCreatedDeepInside() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let changes = Counter()
        let watcher = try #require(DirectoryWatcher(directory: dir, latency: 0.2) { _ in changes.increment() })

        try Data(repeating: 1, count: 10).write(to: dir.appendingPathComponent("a/b/new"))
        #expect(await wait(for: changes))
        withExtendedLifetime(watcher) {}
    }

    @Test func reportsTheDirectoryThatChanged() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await Task.sleep(for: .seconds(1))
        let changed = Paths()
        let watcher = try #require(DirectoryWatcher(directory: dir, latency: 0.2) { changed.add($0) })

        try Data(repeating: 1, count: 10).write(to: dir.appendingPathComponent("a/b/new"))
        let expected = dir.appendingPathComponent("a/b").resolvingSymlinksInPath().path
        var seen = false
        for _ in 0..<50 where !seen {
            // FSEvents reports the real path, `/private` and all.
            seen = changed.value.contains { $0.hasSuffix(expected + "/") || $0.hasSuffix(expected) }
            if !seen { try? await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(seen)
        withExtendedLifetime(watcher) {}
    }

    @Test func reportsAFileGrowing() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a/blob")
        try Data(repeating: 1, count: 10).write(to: file)
        // Let the events from creating the file pass before watching.
        try await Task.sleep(for: .seconds(1))
        let changes = Counter()
        let watcher = try #require(DirectoryWatcher(directory: dir, latency: 0.2) { _ in changes.increment() })

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 2, count: 100_000))
        try handle.close()
        #expect(await wait(for: changes))
        withExtendedLifetime(watcher) {}
    }

    @Test func staysQuietWhenNothingChanges() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Let the events from creating the directory pass before watching.
        try await Task.sleep(for: .seconds(1))
        let changes = Counter()
        let watcher = try #require(DirectoryWatcher(directory: dir, latency: 0.2) { _ in changes.increment() })

        try await Task.sleep(for: .seconds(1))
        #expect(changes.value == 0)
        withExtendedLifetime(watcher) {}
    }

    @Test func stopsReportingOnceReleased() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let changes = Counter()
        var watcher = DirectoryWatcher(directory: dir, latency: 0.2) { _ in changes.increment() }
        #expect(watcher != nil)
        watcher = nil

        try Data(repeating: 1, count: 10).write(to: dir.appendingPathComponent("a/new"))
        try await Task.sleep(for: .seconds(1))
        #expect(changes.value == 0)
    }
}
