import Foundation

/// The remote each checkout lists the pull requests and issues of, by path,
/// for the ones whose remote has been chosen: the others show the one gh
/// would work on. Shared by every tab, as repository pins are, and saved to
/// user defaults.
@MainActor
final class RemoteChoices {
    static let shared = RemoteChoices()
    private static let key = "chosenRemotes"

    /// Remote names, by checkout path.
    private var names: [String: String]

    private init() {
        names = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    func chosen(for checkout: URL) -> String? {
        names[checkout.path]
    }

    func choose(_ name: String, for checkout: URL) {
        names[checkout.path] = name
        UserDefaults.standard.set(names, forKey: Self.key)
    }
}
