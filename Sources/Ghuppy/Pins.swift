import Foundation
import GhuppyCore
import Observation

/// Repositories pinned to the top of the list, by path. Shared by every tab,
/// so a repository pinned in one shows pinned in any other that lists it,
/// and saved to user defaults.
@MainActor @Observable
final class Pins {
    static let shared = Pins()
    private static let key = "pinnedRepositories"

    private(set) var paths: Set<String>

    private init() {
        paths = Set(UserDefaults.standard.stringArray(forKey: Self.key) ?? [])
    }

    func isPinned(_ url: URL) -> Bool {
        paths.contains(url.path)
    }

    func toggle(_ url: URL) {
        if paths.remove(url.path) == nil {
            paths.insert(url.path)
        }
        UserDefaults.standard.set(paths.sorted(), forKey: Self.key)
    }
}

/// Pull requests and issues pinned to stay listed once merged or closed, by
/// repository on GitHub, so every checkout of one, in any tab, shares them.
/// Saved to user defaults.
@MainActor @Observable
final class RowPins {
    static let shared = RowPins()

    enum Kind: String {
        case pullRequest = "pinnedPullRequests"
        case issue = "pinnedIssues"
    }

    /// The numbers pinned, by kind, then by repository: `owner/name`,
    /// lowercased, as GitHub takes either case.
    private var numbers: [Kind: [String: Set<Int>]]

    private init() {
        numbers = [:]
        for kind in [Kind.pullRequest, .issue] {
            let saved = UserDefaults.standard.dictionary(forKey: kind.rawValue) as? [String: [Int]] ?? [:]
            numbers[kind] = saved.mapValues(Set.init)
        }
    }

    private static func key(_ repo: GitHubRepo) -> String { repo.slug.lowercased() }

    func isPinned(_ number: Int, _ kind: Kind, in repo: GitHubRepo) -> Bool {
        numbers[kind]?[Self.key(repo)]?.contains(number) ?? false
    }

    func toggle(_ number: Int, _ kind: Kind, in repo: GitHubRepo) {
        var pinned = numbers[kind]?[Self.key(repo)] ?? []
        if pinned.remove(number) == nil {
            pinned.insert(number)
        }
        numbers[kind, default: [:]][Self.key(repo)] = pinned.isEmpty ? nil : pinned
        UserDefaults.standard.set(numbers[kind]?.mapValues { $0.sorted() } ?? [:], forKey: kind.rawValue)
    }

    /// What a reload of `repo` looks up besides its latest.
    func pinned(in repo: GitHubRepo) -> PullRequests.Pinned {
        PullRequests.Pinned(pullRequests: numbers[.pullRequest]?[Self.key(repo)] ?? [],
                            issues: numbers[.issue]?[Self.key(repo)] ?? [])
    }
}
