import Observation

/// Runs one job at a time. Starting a job cancels the one running and begins
/// once that has unwound, so two jobs never write over each other, and of
/// several started in a row only the last gets to run.
@MainActor @Observable
public final class RefreshSlot {
    /// How many jobs are yet to finish: the one running and any behind it.
    private var unfinished = 0
    @ObservationIgnored private var latest: Task<Void, Never>?

    /// True from the moment a job is started until the last one has finished,
    /// with no gap when one takes over from another.
    public var isRunning: Bool { unfinished > 0 }

    public init() {}

    @discardableResult
    public func start(_ job: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = latest
        previous?.cancel()
        unfinished += 1
        let task = Task {
            await previous?.value
            if !Task.isCancelled { await job() }
            unfinished -= 1
        }
        latest = task
        return task
    }
}
