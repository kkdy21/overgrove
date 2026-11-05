/// Per-file change statistics for a commit or a stash (`diff-tree --raw --numstat`, parsing-spec.md §8).
struct FileStat: Sendable, Hashable {
    let path: GitPath
    let originalPath: GitPath?
    /// `nil` when only numstat output is available (stashes).
    let status: FileChange.Status?
    /// `nil` for binary files.
    let added: Int?
    let deleted: Int?
    /// True for files that came from the stash's untracked part (`stash -u`).
    let isFromUntracked: Bool

    init(
        path: GitPath,
        originalPath: GitPath? = nil,
        status: FileChange.Status? = nil,
        added: Int?,
        deleted: Int?,
        isFromUntracked: Bool = false
    ) {
        self.path = path
        self.originalPath = originalPath
        self.status = status
        self.added = added
        self.deleted = deleted
        self.isFromUntracked = isFromUntracked
    }

    var isBinary: Bool { added == nil && deleted == nil }
}
