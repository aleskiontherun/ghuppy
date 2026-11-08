import Foundation

/// Tells whether a repository's pull requests may have changed since the
/// last look, for close to nothing: it asks GitHub's REST API with the ETag
/// of its last answer, and a `304 Not Modified` doesn't count against the
/// rate limit. Reloading the pull requests themselves takes GraphQL, which
/// can't answer that way, so the reload only happens once this says so.
///
/// Two answers are watched. The pull requests ordered by their last update,
/// whose first changes whenever any of them is opened, pushed to, reviewed,
/// edited, closed or merged. And the latest workflow runs, which change as
/// checks start and finish and as the merge queue tests what it holds:
/// neither moves a pull request's update time. Checks reported by anything
/// other than GitHub Actions show up at the next refresh.
public actor PullRequestChanges {
    public static let shared = PullRequestChanges()

    /// The ETag of the last answer to each URL.
    private var tags: [String: String] = [:]

    public init() {}

    /// The URLs whose answers are watched for `repo`.
    static func urls(for repo: GitHubRepo) -> [String] {
        [
            "repos/\(repo.slug)/pulls?state=all&sort=updated&direction=desc&per_page=1",
            "repos/\(repo.slug)/actions/runs?per_page=20",
        ]
    }

    /// Whether anything watched changed since the last call for `repo`, or
    /// whether this is the first: either way, what's on screen may be out of
    /// date. A URL GitHub doesn't answer counts as unchanged, so a failure
    /// costs no reload. Throws `RateLimitError` while requests are paused,
    /// and `CancellationError` when the calling task is cancelled.
    @discardableResult
    public func check(_ repo: GitHubRepo, cwd: URL) async throws -> Bool {
        var changed = false
        for url in Self.urls(for: repo) {
            var args = ["api", "--include", "--jq", "type"]
            if let tag = tags[url] { args += ["--header", "If-None-Match: \(tag)"] }
            // A 304 is a failure to `gh`, which isn't worth retrying.
            let result = try await PullRequests.gh(args + [url], cwd: cwd, retryDelays: [])
            let response = Self.response(result.stdout)
            guard response.status == 200, let tag = response.etag else { continue }
            if tags[url] != tag { changed = true }
            tags[url] = tag
        }
        return changed
    }

    /// The status code and ETag of what `gh api --include` printed: the
    /// status line, then the headers, a blank line and the body, the headers
    /// ending in `\r\n`, which Swift counts as one character. GitHub marks
    /// the ETag of a `200` weak, `W/"…"`, and sends the same one back strong
    /// with a `304`, so the mark is dropped.
    static func response(_ output: String) -> (status: Int?, etag: String?) {
        var lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).makeIterator()
        let status = lines.next()?.split(separator: " ").dropFirst().first.flatMap { Int($0) }
        var etag: String?
        while let line = lines.next()?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].caseInsensitiveCompare("etag") == .orderedSame else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            etag = value.hasPrefix("W/") ? String(value.dropFirst(2)) : value
        }
        return (status, etag)
    }
}
