import Foundation

/// What a running action reports.
public enum ActionEvent: Sendable, Equatable {
    /// Lines it wrote, the ones on stderr marked as errors.
    case output([String], isError: Bool)
    /// How it ended. Always the last event, unless the stream was cancelled.
    case exited(ActionExit)
}

public enum ActionExit: Sendable, Equatable {
    case status(Int32)
    case signal(Int32)
    case failedToStart(String)

    public var succeeded: Bool { self == .status(0) }

    public var description: String {
        switch self {
        case let .status(code): "exited with \(code)"
        case let .signal(number): "terminated by \(String(cString: strsignal(number)).lowercased())"
        case let .failedToStart(reason): "couldn't start: \(reason)"
        }
    }
}

/// Runs a repository action's command line in `zsh -l -c`, in the
/// repository's directory, with nothing on stdin, and streams what it writes
/// line by line. A login shell, so the PATH set in `~/.zprofile` (Homebrew's,
/// say) is there even when Ghuppy was opened from Finder.
///
/// The shell leads a process group of its own, which everything it starts
/// joins, so cancelling the stream terminates all of it, not just the shell.
public final class ActionProcess: @unchecked Sendable {
    /// How long a process group has between SIGTERM and SIGKILL.
    static let killAfter: DispatchTimeInterval = .seconds(5)
    /// How long output is still read after the shell exits, from processes
    /// it left running in the background with the pipes open.
    static let drainAfterExit: DispatchTimeInterval = .seconds(1)
    /// The longest line kept whole: a longer one is cut into pieces.
    static let longestLine = 64 * 1024

    public static func run(_ command: String, in directory: URL, shell: String = "/bin/zsh") -> AsyncStream<ActionEvent> {
        AsyncStream { continuation in
            let process = ActionProcess(continuation: continuation)
            continuation.onTermination = { reason in
                if case .cancelled = reason { process.terminate() }
            }
            process.start(shell: shell, arguments: ["-l", "-c", command], directory: directory)
        }
    }

    /// The process groups of the actions still running, for `terminateAll`.
    private static let running = Running()

    /// Terminates every action still running, there and then: for the app
    /// to call as it quits, since a process group of its own outlives it.
    public static func terminateAll() {
        running.forEach { kill(-$0, SIGTERM) }
    }

    private let continuation: AsyncStream<ActionEvent>.Continuation
    /// Everything below is touched on this queue alone.
    private let queue = DispatchQueue(label: "Ghuppy.ActionProcess")
    private var pid: pid_t = 0
    private var sources: [DispatchSourceRead] = []
    private var buffers: [Int32: Data] = [:]
    private var exit: ActionExit?
    private var finished = false
    private var terminating = false

    private init(continuation: AsyncStream<ActionEvent>.Continuation) {
        self.continuation = continuation
    }

    private func start(shell: String, arguments: [String], directory: URL) {
        queue.async { [self] in
            var out: [Int32] = [-1, -1], err: [Int32] = [-1, -1]
            guard pipe(&out) == 0 else { return fail(errno) }
            guard pipe(&err) == 0 else {
                close(out[0]); close(out[1])
                return fail(errno)
            }
            // Kept out of anything else the app starts meanwhile, which would
            // hold the write ends open and the output would never end.
            for fd in out + err { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_adddup2(&actions, out[1], 1)
            posix_spawn_file_actions_adddup2(&actions, err[1], 2)
            posix_spawn_file_actions_addchdir_np(&actions, directory.path)

            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            // Its own process group, every other descriptor closed, and the
            // signals as a shell started from a terminal would find them.
            posix_spawnattr_setflags(&attributes, Int16(
                POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
            ))
            posix_spawnattr_setpgroup(&attributes, 0)
            var all = sigset_t(), none = sigset_t()
            sigfillset(&all)
            sigemptyset(&none)
            posix_spawnattr_setsigdefault(&attributes, &all)
            posix_spawnattr_setsigmask(&attributes, &none)

            var environment = Shell.environment
            environment["TERM"] = "dumb"
            let argv = ([shell] + arguments).map { strdup($0) } + [nil]
            let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer {
                argv.forEach { free($0) }
                envp.forEach { free($0) }
            }
            var pid: pid_t = 0
            let spawned = posix_spawn(&pid, shell, &actions, &attributes, argv, envp)
            close(out[1])
            close(err[1])
            guard spawned == 0 else {
                close(out[0]); close(err[0])
                return fail(spawned)
            }
            self.pid = pid
            Self.running.insert(pid)
            watch(out[0], isError: false)
            watch(err[0], isError: true)
            let child = pid
            DispatchQueue.global(qos: .utility).async { [self] in
                var status: Int32 = 0
                while waitpid(child, &status, 0) == -1 && errno == EINTR {}
                let result = status
                queue.async { [self] in exited(result) }
            }
        }
    }

    private func fail(_ code: Int32) {
        continuation.yield(.exited(.failedToStart(String(cString: strerror(code)))))
        continuation.finish()
        finished = true
    }

    private func watch(_ fd: Int32, isError: Bool) {
        buffers[fd] = Data()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self, unowned source] in
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                buffers[fd, default: Data()].append(contentsOf: chunk[0..<count])
                emit(fd, isError: isError, atEnd: false)
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                source.cancel()
            }
        }
        source.setCancelHandler { [self] in
            emit(fd, isError: isError, atEnd: true)
            buffers[fd] = nil
            close(fd)
            sources.removeAll { $0 === source }
            finishIfDone()
        }
        sources.append(source)
        source.resume()
    }

    /// Sends the complete lines in `fd`'s buffer, and the rest too at its end.
    private func emit(_ fd: Int32, isError: Bool, atEnd: Bool) {
        guard let data = buffers[fd] else { return }
        var lines: [String] = []
        var start = data.startIndex
        while start < data.endIndex {
            let rest = data[start...]
            if let newline = rest.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(Self.clean(data[start..<newline]))
                start = data.index(after: newline)
            } else if rest.count >= Self.longestLine || atEnd {
                let end = data.index(start, offsetBy: min(rest.count, Self.longestLine))
                lines.append(Self.clean(data[start..<end]))
                start = end
            } else {
                break
            }
        }
        buffers[fd] = Data(data[start...])
        if !lines.isEmpty { continuation.yield(.output(lines, isError: isError)) }
    }

    private func exited(_ status: Int32) {
        Self.running.remove(pid)
        let signal = status & 0x7f
        exit = signal == 0 ? .status((status >> 8) & 0xff) : .signal(signal)
        // Anything it left running with the pipes open gets a moment more.
        queue.asyncAfter(deadline: .now() + Self.drainAfterExit) { [self] in
            sources.forEach { $0.cancel() }
        }
        finishIfDone()
    }

    private func finishIfDone() {
        guard !finished, let exit, sources.isEmpty else { return }
        finished = true
        continuation.yield(.exited(exit))
        continuation.finish()
    }

    /// Terminates the shell and everything it started, killing whatever is
    /// still there a few seconds later.
    func terminate() {
        queue.async { [self] in
            guard pid > 0, exit == nil, !terminating else { return }
            terminating = true
            kill(-pid, SIGTERM)
            // Whatever ignored it, even once the shell itself has gone.
            queue.asyncAfter(deadline: .now() + Self.killAfter) { [self] in
                kill(-pid, SIGKILL)
            }
        }
    }

    /// A line as text: what a carriage return overwrote dropped, as a
    /// terminal would show it, and colour codes taken out.
    static func clean(_ bytes: Data) -> String {
        var line = String(decoding: bytes, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        if let carriageReturn = line.lastIndex(of: "\r") {
            line = String(line[line.index(after: carriageReturn)...])
        }
        return line.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }
}

private final class Running: @unchecked Sendable {
    private let lock = NSLock()
    private var pids = Set<pid_t>()

    func insert(_ pid: pid_t) { _ = lock.withLock { pids.insert(pid) } }
    func remove(_ pid: pid_t) { _ = lock.withLock { pids.remove(pid) } }
    func forEach(_ body: (pid_t) -> Void) { lock.withLock { pids }.forEach(body) }
}
