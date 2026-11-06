import Foundation

/// A `gh` call GitHub's rate limit stopped, or one never sent because
/// requests are paused.
public struct RateLimitError: LocalizedError, Sendable, Equatable {
    /// When requests start again.
    public let until: Date

    public var errorDescription: String? {
        "GitHub rate limit reached, requests resume at \(until.formatted(date: .omitted, time: .shortened))"
    }
}

enum RateLimit {
    /// Whether `gh` failed on a rate limit, from what it wrote to stderr: the
    /// exit status is 1 for any failure, and the wording varies with the
    /// command and with how GitHub answered. `gh pr list` says
    /// `GraphQL: API rate limit already exceeded…` or
    /// `HTTP 403: You have exceeded a secondary rate limit…`, and `gh api`
    /// says `gh: …`, with `(HTTP 403)` at the end. A 429 may name no limit at
    /// all, as `HTTP 429: Too many requests`.
    static func isHit(_ stderr: String) -> Bool {
        let text = stderr.lowercased()
        return text.contains("rate limit") || text.contains("abuse detection") || text.contains("http 429")
    }

    /// When the quota comes back, from the GraphQL entry of `gh api
    /// rate_limit`. Nil when some of it is left: the limit hit was then a
    /// secondary one, which that endpoint doesn't report.
    static func reset(fromQuota json: String) -> Date? {
        struct Quota: Decodable {
            let remaining: Int
            let reset: TimeInterval
        }
        guard let quota = try? JSONDecoder().decode(Quota.self, from: Data(json.utf8)), quota.remaining == 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: quota.reset)
    }
}

/// Keeps `gh` calls back after GitHub's rate limit stopped one. The limit is
/// the account's, so one pause covers every repository and tab.
actor RateLimitPause {
    /// How long, in seconds, the first pause lasts when GitHub gives no reset
    /// time: its docs ask for at least a minute, and for longer each time
    /// after that.
    static let firstWait: TimeInterval = 60
    static let longestWait: TimeInterval = 1800

    private var until: Date?
    /// How many pauses in a row have ended with no call getting through.
    private var strikes = 0

    func pausedUntil(now: Date = .now) -> Date? {
        guard let until, until > now else { return nil }
        return until
    }

    /// Records a rate limit error and returns when requests resume. Calls
    /// running side by side fail together, so only the first opens a pause:
    /// one burst counts once. The pause is in force while `quotaReset` runs,
    /// so nothing else goes out meanwhile.
    func hit(now: Date = .now, quotaReset: @Sendable () async -> Date?) async -> Date {
        if let until = pausedUntil(now: now) { return until }
        let wait = min(Self.firstWait * pow(2, Double(strikes)), Self.longestWait)
        strikes += 1
        var resume = now.addingTimeInterval(wait)
        until = resume
        if let reset = await quotaReset(), reset > resume {
            resume = reset
            until = reset
        }
        return resume
    }

    /// A call got through. One that started before a pause proves nothing
    /// about the limit, so it doesn't count during one.
    func succeeded(now: Date = .now) {
        if pausedUntil(now: now) == nil { strikes = 0 }
    }
}
