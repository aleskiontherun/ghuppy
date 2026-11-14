import Foundation

/// What a tab's repository cards and status bar showed, saved so the next
/// launch shows it again at once, while the refresh that launch starts
/// brings it up to date. Errors aren't kept: they describe the last run's
/// attempts, and the new run's own report them in its log.
public struct WorkspaceSnapshot: Codable, Sendable, Equatable {
    public struct Repo: Codable, Sendable, Equatable {
        public var path: URL
        public var name: String
        public var github: GitHubRepo?
        public var status: LocalStatus
        public var branches: Branches?
        public var pullRequests: [PullRequest]
        public var mergedPullRequests: [PullRequest]
        /// Whether the pull requests had loaded, which tells an empty list
        /// from one that never came.
        public var prsLoaded: Bool
        public var result: Result?
        public var size: Int64?
        public var refCounts: RefCounts?

        public init(path: URL, name: String, github: GitHubRepo? = nil, status: LocalStatus = LocalStatus(),
                    branches: Branches? = nil, pullRequests: [PullRequest] = [],
                    mergedPullRequests: [PullRequest] = [], prsLoaded: Bool = false, result: Result? = nil,
                    size: Int64? = nil, refCounts: RefCounts? = nil) {
            self.path = path
            self.name = name
            self.github = github
            self.status = status
            self.branches = branches
            self.pullRequests = pullRequests
            self.mergedPullRequests = mergedPullRequests
            self.prsLoaded = prsLoaded
            self.result = result
            self.size = size
            self.refCounts = refCounts
        }
    }

    /// The outcome of the last cleanup or branch switch.
    public struct Result: Codable, Sendable, Equatable {
        public var text: String
        public var isError: Bool

        public init(text: String, isError: Bool) {
            self.text = text
            self.isError = isError
        }
    }

    public var root: URL
    public var repos: [Repo]
    public var directorySize: Int64?

    public init(root: URL, repos: [Repo], directorySize: Int64? = nil) {
        self.root = root
        self.repos = repos
        self.directorySize = directorySize
    }
}

/// The snapshots of every open tab, kept in one file.
public enum Snapshots {
    /// Goes up whenever what's saved changes shape. A file of another
    /// version is passed over rather than read, and the next save replaces it.
    static let version = 1

    private struct Header: Decodable {
        let version: Int
    }

    private struct File: Codable {
        var version: Int
        var workspaces: [WorkspaceSnapshot]
    }

    public static func encode(_ snapshots: [WorkspaceSnapshot]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // The same snapshots always make the same bytes, which tells a save
        // that would change nothing.
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(File(version: version, workspaces: snapshots))
    }

    /// The snapshots in `data`, none when it was saved by another version.
    public static func decode(_ data: Data) throws -> [WorkspaceSnapshot] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard try decoder.decode(Header.self, from: data).version == version else { return [] }
        return try decoder.decode(File.self, from: data).workspaces
    }

    /// The snapshots saved at `url`, none when nothing has been saved there.
    public static func load(from url: URL) throws -> [WorkspaceSnapshot] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        return try decode(data)
    }

    /// Writes `data`, made by `encode`, to `url`, in place of whatever was
    /// saved there: the file is replaced whole, so a crash mid-write leaves
    /// the last one.
    public static func save(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
