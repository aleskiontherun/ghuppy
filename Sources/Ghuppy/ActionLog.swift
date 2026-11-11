import AppKit
import GhuppyCore
import Observation

/// A log tab of its own for one repository's action: what its last run
/// wrote, and how it ended. Running the action again clears it and reuses it.
@MainActor @Observable
final class ActionLog: Identifiable {
    enum State: Equatable {
        case running
        case finished(ActionExit)
        case stopped
    }

    let repo: URL
    let repoName: String
    private(set) var action: RepoAction
    private(set) var lines: [LogLine] = []
    private(set) var state: State = .running
    @ObservationIgnored private var task: Task<Void, Never>?

    nonisolated static func id(repo: URL, action: String) -> String { "\(repo.path)\n\(action)" }
    nonisolated let id: String

    var title: String { "\(repoName) · \(action.name)" }
    var isRunning: Bool { state == .running }

    init(repo: URL, repoName: String, action: RepoAction) {
        self.repo = repo
        self.repoName = repoName
        self.action = action
        id = Self.id(repo: repo, action: action.name)
    }

    /// Runs `action` from the start, in place of what the tab showed. It
    /// does nothing while the last run is still going.
    func start(_ action: RepoAction) {
        guard task == nil else { return }
        self.action = action
        lines = []
        state = .running
        LogLine.append([LogLine(repo: nil, text: "$ \(action.run)", isError: false)], to: &lines)
        task = Task {
            var exit: ActionExit?
            for await event in ActionProcess.run(action.run, in: repo) {
                switch event {
                case let .output(text, isError):
                    LogLine.append(text.map { LogLine(repo: nil, text: $0, isError: isError) }, to: &lines)
                case let .exited(how):
                    exit = how
                }
            }
            // A cancelled stream ends without saying how the action did.
            if let exit, !Task.isCancelled {
                state = .finished(exit)
                LogLine.append([LogLine(repo: nil, text: exit.description, isError: !exit.succeeded)], to: &lines)
            } else {
                state = .stopped
                LogLine.append([LogLine(repo: nil, text: "Stopped", isError: false)], to: &lines)
            }
            task = nil
        }
    }

    /// Stops the run under way, and everything it started.
    func stop() {
        task?.cancel()
    }

    func clear() {
        lines.removeAll()
    }
}

extension RepoAction {
    /// The configured SF Symbol, or the default one when there is no symbol
    /// by that name.
    var symbol: String {
        NSImage(systemSymbolName: icon, accessibilityDescription: nil) == nil ? Self.defaultIcon : icon
    }
}
