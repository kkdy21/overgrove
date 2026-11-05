/// Kinds of unmerged entries in `git status --porcelain=v2` (`u` records, parsing-spec.md §3.3).
enum ConflictKind: String, Sendable, Hashable, CaseIterable {
    case bothDeleted = "DD"
    case addedByUs = "AU"
    case deletedByThem = "UD"
    case addedByThem = "UA"
    case deletedByUs = "DU"
    case bothAdded = "AA"
    case bothModified = "UU"
}

/// One file in a worktree's working state (parsing-spec.md §3).
struct FileChange: Sendable, Hashable {
    enum Status: Sendable, Hashable {
        case modified
        case typeChanged
        case added
        case deleted
        case renamed(score: Int?)
        case copied(score: Int?)
        case untracked
        case conflicted(ConflictKind)

        /// One-letter code for compact display (`M`, `T`, `A`, `D`, `R`, `C`, `?`, `U`).
        var code: Character {
            switch self {
            case .modified: "M"
            case .typeChanged: "T"
            case .added: "A"
            case .deleted: "D"
            case .renamed: "R"
            case .copied: "C"
            case .untracked: "?"
            case .conflicted: "U"
            }
        }
    }

    let path: GitPath
    /// Previous path for renames and copies.
    let originalPath: GitPath?
    let status: Status
    let isSubmodule: Bool

    init(path: GitPath, originalPath: GitPath? = nil, status: Status, isSubmodule: Bool = false) {
        self.path = path
        self.originalPath = originalPath
        self.status = status
        self.isSubmodule = isSubmodule
    }
}
