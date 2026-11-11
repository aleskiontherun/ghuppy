import Foundation
import Testing
@testable import GhuppyCore

struct RepoActionsTests {
    @Test func readsTheActionsInOrder() throws {
        let actions = try RepoActions.parse("""
        # Comments are fine.
        actions:
          - name: Test
            icon: checkmark.seal
            run: swift test
          - name: "Build app"
            run: |
              swift build
              ./scripts/build-app.sh
        """)
        #expect(actions == [
            RepoAction(name: "Test", icon: "checkmark.seal", run: "swift test"),
            RepoAction(name: "Build app", icon: RepoAction.defaultIcon, run: "swift build\n./scripts/build-app.sh"),
        ])
    }

    @Test func anEmptyFileHasNoActions() throws {
        #expect(try RepoActions.parse("").isEmpty)
        #expect(try RepoActions.parse("# nothing yet\n").isEmpty)
        #expect(try RepoActions.parse("actions: []").isEmpty)
    }

    @Test func otherKeysAreIgnored() throws {
        let actions = try RepoActions.parse("""
        version: 2
        actions:
          - name: Lint
            run: shellcheck scripts/*.sh
            when: always
        """)
        #expect(actions.map(\.name) == ["Lint"])
    }

    @Test(arguments: [
        ("actions:\n  - icon: hammer\n    run: make", "action 1 has no name"),
        ("actions:\n  - name: Build\n", "action “Build” has nothing to run"),
        ("actions:\n  - name: Build\n    run: '  '", "action “Build” has nothing to run"),
        ("actions:\n  - name: A\n    run: a\n  - name: A\n    run: b", "more than one action is called “A”"),
        ("actions: make", "actions isn't what Ghuppy expects"),
    ])
    func rejectsWhatItCantRun(yaml: String, message: String) {
        #expect(throws: RepoActionsError(message: "ghuppy.yaml: \(message)")) {
            try RepoActions.parse(yaml)
        }
    }

    @Test func rejectsYAMLThatDoesntParse() {
        #expect(throws: RepoActionsError.self) {
            try RepoActions.parse("actions:\n  - name: [unclosed\n")
        }
    }

    @Test func aRepositoryWithoutTheFileHasNoActions() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try RepoActions.load(from: directory).get().isEmpty)
    }

    @Test func loadsTheFileAtTheRoot() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "actions:\n  - name: Hi\n    run: echo hi\n"
            .write(to: directory.appendingPathComponent("ghuppy.yaml"), atomically: true, encoding: .utf8)
        #expect(try RepoActions.load(from: directory).get() == [RepoAction(name: "Hi", run: "echo hi")])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ghuppy-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

struct ActionProcessTests {
    private let cwd = FileManager.default.temporaryDirectory

    /// `resolvingSymlinksInPath` drops the `/private` that `pwd -P` keeps.
    private var physicalCwd: String {
        cwd.withUnsafeFileSystemRepresentation { path in
            let resolved = realpath(path!, nil)!
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    /// Runs `command` with `/bin/sh`, which unlike a login zsh reads nothing
    /// of the machine's own setup.
    private func run(_ command: String, in directory: URL? = nil) async -> (out: [String], err: [String], exit: ActionExit?) {
        var out: [String] = [], err: [String] = [], exit: ActionExit?
        for await event in ActionProcess.run(command, in: directory ?? cwd, shell: "/bin/sh") {
            switch event {
            case let .output(lines, isError): if isError { err += lines } else { out += lines }
            case let .exited(how): exit = how
            }
        }
        return (out, err, exit)
    }

    @Test func streamsStdoutAndStderrApart() async {
        let result = await run("echo one; echo two >&2; printf 'three'")
        #expect(result.out == ["one", "three"])
        #expect(result.err == ["two"])
        #expect(result.exit == .status(0))
    }

    @Test func reportsTheExitStatus() async {
        #expect(await run("exit 3").exit == .status(3))
        #expect(await run("kill -TERM $$").exit == .signal(SIGTERM))
    }

    @Test func runsInTheDirectoryGivenWithNothingOnStdin() async {
        let result = await run("pwd -P; cat; echo done")
        #expect(result.out == [physicalCwd, "done"])
    }

    @Test func aMissingShellFailsToStart() async {
        var exit: ActionExit?
        for await event in ActionProcess.run("true", in: cwd, shell: "/nonexistent/sh") {
            if case let .exited(how) = event { exit = how }
        }
        guard case .failedToStart = exit else {
            Issue.record("expected a failure to start, got \(String(describing: exit))")
            return
        }
    }

    @Test func cancellingTerminatesEverythingItStarted() async throws {
        let marker = cwd.appendingPathComponent("ghuppy-action-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        // The child outlives a shell that only passes its SIGTERM on to it
        // when it's in the same process group. It touches the marker 4
        // seconds after "started", before the SIGKILL that follows the
        // cancel by 5, so only the SIGTERM reaching it keeps the marker away.
        let (ready, signal) = AsyncStream<Void>.makeStream()
        let task = Task {
            for await event in ActionProcess.run(
                "echo started; (sleep 4; touch '\(marker.path)') & wait", in: cwd, shell: "/bin/sh"
            ) {
                if case .output = event { signal.yield() }
            }
        }
        // Cancelled once the child is running, not after a fixed wait, and
        // nothing is timed: a busy CI runner can stall every test for
        // seconds. A stream that ignored the cancel would leave the marker.
        for await _ in ready { break }
        task.cancel()
        _ = await task.value
        try await Task.sleep(for: .seconds(5))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func cleansLinesAsATerminalWouldShowThem() {
        #expect(ActionProcess.clean(Data("50%\r100%\r".utf8)) == "100%")
        #expect(ActionProcess.clean(Data("\u{1B}[1;32mok\u{1B}[0m".utf8)) == "ok")
    }
}
