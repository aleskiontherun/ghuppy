import Testing
@testable import GhuppyCore

@Suite struct PullRequestChangesParsing {
    /// What `gh api --include --jq type` printed, with fewer headers: they end
    /// in `\r\n`, the body in `\n`.
    func output(_ head: String, body: String = "") -> String {
        head.split(separator: "\n").joined(separator: "\r\n") + "\r\n\r\n" + body
    }

    @Test func readsAnAnswerThatChanged() {
        let response = PullRequestChanges.response(output("""
        HTTP/2.0 200 OK
        Cache-Control: private, max-age=60, s-maxage=60
        Etag: W/"f1c48e84"
        X-Ratelimit-Remaining: 4962
        """, body: "array\n"))
        #expect(response.status == 200)
        #expect(response.etag == #""f1c48e84""#)
    }

    @Test func readsTheSameTagBackFromANotModified() {
        let response = PullRequestChanges.response(output("""
        HTTP/2.0 304 Not Modified
        Etag: "f1c48e84"
        """))
        #expect(response.status == 304)
        #expect(response.etag == #""f1c48e84""#)
    }

    @Test func stopsAtTheBody() {
        let response = PullRequestChanges.response(output("""
        HTTP/2.0 404 Not Found
        Content-Type: application/json
        """, body: "Etag: \"nope\"\n"))
        #expect(response.status == 404)
        #expect(response.etag == nil)
    }

    @Test(arguments: ["", "gh: HTTP 304", "not a response"])
    func hasNothingToReadIn(_ output: String) {
        let response = PullRequestChanges.response(output)
        #expect(response.status == nil)
        #expect(response.etag == nil)
    }

    @Test func watchesTheLatestUpdateAndTheLatestRuns() {
        #expect(PullRequestChanges.urls(for: GitHubRepo(owner: "octo", name: "hello")) == [
            "repos/octo/hello/pulls?state=all&sort=updated&direction=desc&per_page=1",
            "repos/octo/hello/actions/runs?per_page=20",
        ])
    }
}
