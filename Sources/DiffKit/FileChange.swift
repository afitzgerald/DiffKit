import Foundation

// MARK: - File changes

public enum FileChangeStatus: String, Codable, Sendable {
    case added, modified, removed, renamed, copied, changed
}

public struct FileChange: Codable, Hashable, Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    public var previousPath: String?
    public var status: FileChangeStatus
    public var additions: Int
    public var deletions: Int
    /// Unified diff body for this file (no `diff --git` header), nil for binary/too-large.
    public var patch: String?
    public var isBinary: Bool

    public init(path: String, previousPath: String? = nil, status: FileChangeStatus,
                additions: Int, deletions: Int, patch: String?, isBinary: Bool = false) {
        self.path = path
        self.previousPath = previousPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.patch = patch
        self.isBinary = isBinary
    }
}
