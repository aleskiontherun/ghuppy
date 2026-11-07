import Foundation

public struct ShellResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public var ok: Bool { status == 0 }
    public var out: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var err: String { stderr.trimmingCharacters(in: .whitespacesAndNewlines) }
}

public struct ShellError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// Runs command-line tools on behalf of the app.
///
/// An app launched from Finder inherits launchd's minimal PATH, which has
/// neither Homebrew's `gh` nor a user-installed `git` in it, so the usual
/// install locations are appended before looking anything up.
public enum Shell {
    static let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        var path = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for extra in extraPaths where !path.contains(extra) {
            path.append(extra)
        }
        env["PATH"] = path.joined(separator: ":")
        // Never block on a prompt nobody can see.
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GH_PROMPT_DISABLED"] = "1"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["NO_COLOR"] = "1"
        return env
    }()

    static func locate(_ tool: String) -> String? {
        let dirs = (environment["PATH"] ?? "").split(separator: ":")
        for dir in dirs {
            let candidate = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    public static let gitPath = locate("git")
    public static let ghPath = locate("gh")

    /// Runs `tool` to the end. Cancelling the calling task terminates it, or
    /// keeps it from starting, so the result is then a failure that says
    /// nothing about the tool: check for cancellation before reading it.
    public static func run(
        _ tool: String, _ args: [String], cwd: URL, stdin: String? = nil
    ) async -> ShellResult {
        let launcher = Launcher()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: runSync(tool, args, cwd: cwd, stdin: stdin, launcher: launcher))
                }
            }
        } onCancel: {
            launcher.terminate()
        }
    }

    private static func runSync(
        _ tool: String, _ args: [String], cwd: URL, stdin: String?, launcher: Launcher
    ) -> ShellResult {
        guard let executable = tool.hasPrefix("/") ? tool : locate(tool) else {
            return ShellResult(status: 127, stdout: "", stderr: "\(tool): command not found")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = cwd
        process.environment = environment

        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        do {
            guard try launcher.launch(process) else {
                return ShellResult(status: SIGTERM, stdout: "", stderr: "")
            }
        } catch {
            return ShellResult(status: 126, stdout: "", stderr: error.localizedDescription)
        }

        if let stdin {
            // A process terminated before reading this has closed the pipe,
            // and writing to it must not take the app down with SIGPIPE.
            _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            try? inPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
        }
        try? inPipe.fileHandleForWriting.close()

        // Drain stderr on its own thread: a process that fills one pipe while
        // we block reading the other would otherwise never exit.
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        return ShellResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errBox.data, as: UTF8.self)
        )
    }
}

/// Starts a process, or terminates it, whichever way the race with
/// cancellation goes.
private final class Launcher: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var terminated = false

    /// Starts `process`, or returns false if it's too late to.
    func launch(_ process: Process) throws -> Bool {
        try lock.withLock {
            guard !terminated else { return false }
            try process.run()
            self.process = process
            return true
        }
    }

    func terminate() {
        lock.withLock {
            terminated = true
            process?.terminate()
        }
    }
}

/// Written by one thread, read by another only after a `DispatchGroup` wait.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}
