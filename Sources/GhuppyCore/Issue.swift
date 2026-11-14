import Foundation

/// Anything listed with the person who opened it, which the author select
/// narrows down.
public protocol Authored {
    var author: PullRequest.Author? { get }
}

extension Authored {
    /// Who opened it, nil when GitHub no longer knows. A bot reads the same
    /// however it was loaded: `gh pr list` calls it `app/dependabot` where
    /// GraphQL says `dependabot`.
    public var authorLogin: String? {
        guard let login = author?.login, !login.isEmpty else { return nil }
        return login.hasPrefix("app/") ? String(login.dropFirst(4)) : login
    }
}

/// An issue, open or closed. Pull requests aren't among them: GitHub's
/// GraphQL `issues` leaves them out.
public struct Issue: Sendable, Identifiable, Codable, Equatable, Authored {
    public let number: Int
    public let title: String
    public let url: URL
    public let author: PullRequest.Author?
    public let updatedAt: Date
    /// When the issue was closed, nil while it's open.
    public let closedAt: Date?
    /// Why it was closed: `COMPLETED`, `NOT_PLANNED` or `DUPLICATE`, or
    /// `REOPENED` for one reopened since. nil while it's never been closed,
    /// and for one closed before GitHub kept a reason.
    public let stateReason: String?

    public var id: Int { number }

    public enum Label: Sendable, CaseIterable {
        case open, closed, notPlanned, duplicate
    }

    public var label: Label {
        guard closedAt != nil else { return .open }
        switch stateReason {
        case "NOT_PLANNED": return .notPlanned
        case "DUPLICATE": return .duplicate
        default: return .closed
        }
    }
}
