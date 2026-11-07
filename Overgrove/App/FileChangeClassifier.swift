import Foundation

/// What a batch of file system events means for one repository (auto refresh, #119).
struct FileChangeSet: Equatable, Sendable {
    /// Worktrees whose status may have changed (their files, `HEAD`, or `index`).
    var worktrees: Set<GitPath> = []
    /// `refs/` or `packed-refs` changed: branches, tags, or remote-tracking refs moved.
    var refs = false
    /// `worktrees/<id>` appeared, disappeared, or changed its lock or location: the worktree list changed.
    var worktreeList = false

    var isEmpty: Bool { worktrees.isEmpty && !refs && !worktreeList }

    mutating func merge(_ other: FileChangeSet) {
        worktrees.formUnion(other.worktrees)
        refs = refs || other.refs
        worktreeList = worktreeList || other.worktreeList
    }
}

/// One FSEvents event: a path and whether the system lost detail and asks for a rescan of the whole tree.
struct FileEvent: Equatable, Sendable {
    let path: String
    /// `kFSEventStreamEventFlagMustScanSubDirs` (events were coalesced or dropped) or a watched root changed.
    var needsRescan = false
}

/// Maps event paths to the worktrees they affect (#119). Pure, so it is tested without FSEvents.
///
/// Event paths are untrusted strings (a repository can name files anything): they are only compared component by
/// component with the canonical folders of worktrees that `RepositoryService` already verified (#226). Nothing is
/// read from disk here, and a path outside every watched folder is ignored.
///
/// In the shared git directory only what changes a status or the lists counts (#163): `HEAD` and `index` (the main
/// worktree), `refs/` and `packed-refs`, `worktrees/<id>/HEAD|index` (that linked worktree), `worktrees/<id>` itself
/// and its `gitdir`/`locked` (the list), and `config` (everything, it can change how queries run). Objects, logs,
/// `FETCH_HEAD`, `ORIG_HEAD`, hooks and the rest are ignored, so a fetch or gc does not re-run every status.
struct FileChangeClassifier: Equatable, Sendable {
    struct WatchedWorktree: Equatable, Sendable {
        let path: GitPath
        /// The worktree folder after `realpath(3)`.
        let folder: String
        /// `<common>` for the main worktree, `<common>/worktrees/<id>` for a linked one (canonical).
        let gitDirectory: String
    }

    let commonDirectory: String
    let worktrees: [WatchedWorktree]

    /// Folders to give FSEvents: every worktree folder and the shared git directory.
    var watchedPaths: [String] {
        Array(Set(worktrees.map(\.folder) + [commonDirectory])).sorted()
    }

    func classify(_ events: [FileEvent]) -> FileChangeSet {
        var change = FileChangeSet()
        for event in events {
            if event.needsRescan {
                // The system lost the detail: assume everything under that root changed.
                change.merge(everything)
                continue
            }
            change.merge(classify(path: event.path))
        }
        return change
    }

    /// Every worktree, the refs, and the list (a rescan, or `config` changed).
    var everything: FileChangeSet {
        FileChangeSet(worktrees: Set(worktrees.map(\.path)), refs: true, worktreeList: true)
    }

    private func classify(path: String) -> FileChangeSet {
        let components = Self.components(path)
        guard !components.isEmpty else { return FileChangeSet() }
        if let relative = Self.relative(components, to: commonDirectory) {
            return classifyGitDirectory(relative)
        }
        // The deepest worktree folder that contains the path (a worktree can sit inside another one).
        let matches = worktrees.compactMap { worktree -> (WatchedWorktree, [Substring])? in
            Self.relative(components, to: worktree.folder).map { (worktree, $0) }
        }
        guard let (worktree, relative) = matches.max(by: { $0.0.folder.count < $1.0.folder.count }) else {
            return FileChangeSet()
        }
        // A linked worktree's `.git` file, or a nested repository's git directory: not this worktree's files.
        if relative.first == ".git" { return FileChangeSet() }
        return FileChangeSet(worktrees: [worktree.path])
    }

    private func classifyGitDirectory(_ relative: [Substring]) -> FileChangeSet {
        guard let first = relative.first else { return FileChangeSet() }
        switch first {
        case "HEAD", "index":
            guard relative.count == 1, let main = worktrees.first(where: { $0.gitDirectory == commonDirectory })
            else { return FileChangeSet() }
            return FileChangeSet(worktrees: [main.path])
        case "refs", "packed-refs":
            return FileChangeSet(refs: true)
        case "config":
            return relative.count == 1 ? everything : FileChangeSet()
        case "worktrees":
            guard relative.count >= 2 else { return FileChangeSet(worktreeList: true) }
            if relative.count == 2 { return FileChangeSet(worktreeList: true) }
            switch relative[2] {
            case "HEAD", "index":
                guard relative.count == 3 else { return FileChangeSet() }
                let gitDirectory = commonDirectory + "/worktrees/" + relative[1]
                guard let linked = worktrees.first(where: { $0.gitDirectory == gitDirectory }) else {
                    return FileChangeSet()
                }
                return FileChangeSet(worktrees: [linked.path])
            case "gitdir", "locked":
                return FileChangeSet(worktreeList: true)
            default:
                return FileChangeSet()
            }
        default:
            return FileChangeSet()
        }
    }

    /// Path components of an absolute path; empty for anything else. `.` and `..` make the path unusable.
    private static func components(_ path: String) -> [Substring] {
        guard path.hasPrefix("/") else { return [] }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains(where: { $0 == "." || $0 == ".." }) else { return [] }
        return parts
    }

    /// The components below `root` (empty for the root itself), or `nil` when the path is not inside it.
    private static func relative(_ components: [Substring], to root: String) -> [Substring]? {
        let rootComponents = Self.components(root)
        guard !rootComponents.isEmpty, components.count >= rootComponents.count,
            Array(components.prefix(rootComponents.count)) == rootComponents
        else { return nil }
        return Array(components.dropFirst(rootComponents.count))
    }
}

extension FileChangeClassifier {
    /// The classifier for a loaded listing: only worktrees whose status was queried, so `RepositoryService` already
    /// proved they belong to the repository (#226); folders resolved with `realpath(3)` (`PathValidator`).
    init?(listing: WorktreeListing, repository: Repository) {
        guard let common = PathValidator.canonical(repository.commonGitDirectoryURL)?.path else { return nil }
        let watched = listing.entries.compactMap { entry -> WatchedWorktree? in
            guard case .loaded = entry.state, entry.worktree.path.isRepresentable,
                let folder = PathValidator.canonical(
                    URL(fileURLWithPath: entry.worktree.path.display, isDirectory: true))
            else { return nil }
            let gitDirectory =
                PathValidator.gitDirectory(of: folder).flatMap { PathValidator.canonical($0)?.path } ?? common
            return WatchedWorktree(path: entry.worktree.path, folder: folder.path, gitDirectory: gitDirectory)
        }
        self.init(commonDirectory: common, worktrees: watched)
    }
}
