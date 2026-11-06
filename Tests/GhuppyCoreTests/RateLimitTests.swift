import Foundation
import Testing
@testable import GhuppyCore

@Suite struct RateLimitDetection {
    /// What `gh` 2.103 wrote to stderr for each kind of response, run against
    /// a fake server.
    @Test(arguments: [
        "GraphQL: API rate limit already exceeded for user ID 1.",
        "gh: API rate limit already exceeded for user ID 1.",
        "HTTP 403: API rate limit exceeded for user ID 1. (https://api.github.com/graphql)",
        "gh: API rate limit exceeded for user ID 1. (HTTP 403)",
        "HTTP 403: You have exceeded a secondary rate limit. Please wait a few minutes before you try again. "
            + "(https://api.github.com/graphql)",
        "gh: You have exceeded a secondary rate limit. Please wait a few minutes before you try again. (HTTP 403)",
        "HTTP 429: Too many requests (https://api.github.com/graphql)",
        "gh: Too many requests (HTTP 429)",
        "HTTP 403: You have triggered an abuse detection mechanism. (https://api.github.com/graphql)",
    ])
    func recognises(_ stderr: String) {
        #expect(RateLimit.isHit(stderr))
    }

    @Test(arguments: [
        "HTTP 499 (https://api.github.com/graphql)",
        "Post \"https://api.github.com/graphql\": unexpected EOF",
        "HTTP 403: Resource not accessible by integration (https://api.github.com/graphql)",
        "GraphQL: Could not resolve to a Repository with the name 'octo/hello'. (repository)",
        "",
    ])
    func leavesOtherFailures(_ stderr: String) {
        #expect(!RateLimit.isHit(stderr))
    }

    @Test func readsTheResetOfAQuotaThatRanOut() {
        let json = #"{"limit":5000,"used":5000,"remaining":0,"reset":1800000000}"#
        #expect(RateLimit.reset(fromQuota: json) == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test(arguments: [#"{"limit":5000,"used":12,"remaining":4988,"reset":1800000000}"#, "", "null"])
    func hasNoResetToWaitFor(_ json: String) {
        #expect(RateLimit.reset(fromQuota: json) == nil)
    }
}

@Suite struct RateLimitPausing {
    let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func notPausedToStartWith() async {
        #expect(await RateLimitPause().pausedUntil(now: start) == nil)
    }

    @Test func aHitPausesForAMinuteAndThenLifts() async {
        let pause = RateLimitPause()
        let until = await pause.hit(now: start) { nil }
        #expect(until == start.addingTimeInterval(60))
        #expect(await pause.pausedUntil(now: start.addingTimeInterval(59)) == until)
        #expect(await pause.pausedUntil(now: until) == nil)
    }

    @Test func waitsForTheQuotaToComeBack() async {
        let pause = RateLimitPause()
        let reset = start.addingTimeInterval(1200)
        #expect(await pause.hit(now: start) { reset } == reset)
        #expect(await pause.pausedUntil(now: start.addingTimeInterval(600)) == reset)
    }

    @Test func aResetAlreadyPastDoesNotShortenThePause() async {
        let pause = RateLimitPause()
        #expect(await pause.hit(now: start) { start.addingTimeInterval(-5) } == start.addingTimeInterval(60))
    }

    @Test func callsFailingTogetherCountOnce() async {
        let pause = RateLimitPause()
        let first = await pause.hit(now: start) { nil }
        let second = await pause.hit(now: start.addingTimeInterval(1)) {
            Issue.record("only the hit that opens a pause looks up the quota")
            return nil
        }
        #expect(second == first)
        let next = await pause.hit(now: first) { nil }
        #expect(next == first.addingTimeInterval(120))
    }

    @Test func waitsDoubleUpToTheLongest() async {
        let pause = RateLimitPause()
        var now = start
        var waits: [TimeInterval] = []
        for _ in 0..<7 {
            let until = await pause.hit(now: now) { nil }
            waits.append(until.timeIntervalSince(now))
            now = until
        }
        #expect(waits == [60, 120, 240, 480, 960, 1800, 1800])
    }

    @Test func aCallGettingThroughStartsTheWaitsAgain() async {
        let pause = RateLimitPause()
        let until = await pause.hit(now: start) { nil }
        await pause.succeeded(now: until)
        #expect(await pause.hit(now: until) { nil } == until.addingTimeInterval(60))
    }

    @Test func aCallFinishingDuringAPauseProvesNothing() async {
        let pause = RateLimitPause()
        let until = await pause.hit(now: start) { nil }
        await pause.succeeded(now: start.addingTimeInterval(1))
        #expect(await pause.hit(now: until) { nil } == until.addingTimeInterval(120))
    }
}

@Suite struct GhAttempts {
    /// Hands out `results` in turn, counting the calls.
    actor Script {
        private var results: [ShellResult]
        private(set) var calls = 0

        init(_ results: [ShellResult]) {
            self.results = results
        }

        func next() -> ShellResult {
            calls += 1
            return results.removeFirst()
        }
    }

    static let ok = ShellResult(status: 0, stdout: "[]", stderr: "")
    static let dropped = ShellResult(status: 1, stdout: "", stderr: "HTTP 499")
    static let limited = ShellResult(status: 1, stdout: "", stderr: "GraphQL: API rate limit exceeded for user ID 1.")

    private func attempt(
        _ script: Script, pause: RateLimitPause = RateLimitPause(), quotaReset: @Sendable () async -> Date? = { nil }
    ) async -> Result<ShellResult, RateLimitError> {
        await PullRequests.attempts(
            retryDelays: [0, 0], pause: pause, run: { await script.next() }, quotaReset: quotaReset
        )
    }

    @Test func retriesOtherFailures() async throws {
        let script = Script([Self.dropped, Self.dropped, Self.ok])
        #expect(try await attempt(script).get().ok)
        #expect(await script.calls == 3)
    }

    @Test func handsBackTheLastOtherFailure() async throws {
        let script = Script([Self.dropped, Self.dropped, Self.dropped])
        #expect(try await attempt(script).get().err == "HTTP 499")
        #expect(await script.calls == 3)
    }

    @Test func doesNotRetryARateLimit() async {
        let script = Script([Self.limited])
        let reset = Date.now.addingTimeInterval(1200)
        let outcome = await attempt(script) { reset }
        #expect(throws: RateLimitError(until: reset)) { try outcome.get() }
        #expect(await script.calls == 1)
    }

    @Test func aRetryStopsAtARateLimit() async {
        let script = Script([Self.dropped, Self.limited])
        let outcome = await attempt(script)
        #expect(throws: RateLimitError.self) { try outcome.get() }
        #expect(await script.calls == 2)
    }

    @Test func sendsNothingWhilePaused() async {
        let pause = RateLimitPause()
        let until = await pause.hit { nil }
        let script = Script([])
        let outcome = await attempt(script, pause: pause)
        #expect(throws: RateLimitError(until: until)) { try outcome.get() }
        #expect(await script.calls == 0)
    }
}
