import Foundation
import Yams

/// A command a repository offers in its `ghuppy.yaml`, run from a button on
/// its card.
public struct RepoAction: Sendable, Hashable, Identifiable {
    /// The icon shown when the configured one is missing.
    public static let defaultIcon = "terminal"

    /// What it is called: its tooltip and its log tab. Unique in the file.
    public let name: String
    /// An SF Symbol name.
    public let icon: String
    /// A zsh command line, run in the repository's directory.
    public let run: String

    public var id: String { name }

    public init(name: String, icon: String = RepoAction.defaultIcon, run: String) {
        self.name = name
        self.icon = icon
        self.run = run
    }
}

public struct RepoActionsError: LocalizedError, Sendable, Equatable {
    public let message: String
    public var errorDescription: String? { message }
}

/// Reads the actions a repository offers from `ghuppy.yaml` at its root:
///
/// ```yaml
/// actions:
///   - name: Test
///     icon: checkmark.seal
///     run: swift test
/// ```
public enum RepoActions {
    public static let fileName = "ghuppy.yaml"

    /// The actions in the repository at `directory`: none when it has no
    /// `ghuppy.yaml`, and an error when the file can't be read or parsed.
    public static func load(from directory: URL) -> Result<[RepoAction], RepoActionsError> {
        let file = directory.appendingPathComponent(fileName)
        let text: String
        do {
            text = try String(contentsOf: file, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return .success([])
        } catch {
            return .failure(RepoActionsError(message: "\(fileName): \(error.localizedDescription)"))
        }
        return Result { () throws(RepoActionsError) in try parse(text) }
    }

    public static func parse(_ yaml: String) throws(RepoActionsError) -> [RepoAction] {
        let config: Config
        do {
            // A file of nothing but comments has no document at all.
            guard let node = try Yams.compose(yaml: yaml) else { return [] }
            config = try YAMLDecoder().decode(Config.self, from: node)
        } catch let error as DecodingError {
            throw RepoActionsError(message: "\(fileName): \(describe(error))")
        } catch {
            throw RepoActionsError(message: "\(fileName): \(error)")
        }
        var actions: [RepoAction] = []
        var names = Set<String>()
        for (index, entry) in (config.actions ?? []).enumerated() {
            let name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let run = entry.run?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let icon = entry.icon?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else {
                throw RepoActionsError(message: "\(fileName): action \(index + 1) has no name")
            }
            guard !run.isEmpty else {
                throw RepoActionsError(message: "\(fileName): action “\(name)” has nothing to run")
            }
            guard names.insert(name).inserted else {
                throw RepoActionsError(message: "\(fileName): more than one action is called “\(name)”")
            }
            actions.append(RepoAction(name: name, icon: icon.isEmpty ? RepoAction.defaultIcon : icon, run: run))
        }
        return actions
    }

    private struct Config: Decodable {
        let actions: [Entry]?
    }

    private struct Entry: Decodable {
        let name: String?
        let icon: String?
        let run: String?
    }

    /// Says where in the file the problem is, rather than which Swift type
    /// didn't decode.
    private static func describe(_ error: DecodingError) -> String {
        func path(_ codingPath: [CodingKey]) -> String {
            let parts = codingPath.map { $0.intValue.map { "action \($0 + 1)" } ?? $0.stringValue }
            return parts.isEmpty ? "the file" : parts.joined(separator: ", ")
        }
        switch error {
        case let .typeMismatch(_, context), let .valueNotFound(_, context):
            return "\(path(context.codingPath)) isn't what Ghuppy expects"
        case let .keyNotFound(key, context):
            return "\(path(context.codingPath + [key])) is missing"
        case let .dataCorrupted(context):
            if let underlying = context.underlyingError { return "\(underlying)" }
            return context.debugDescription
        @unknown default:
            return "\(error)"
        }
    }
}
