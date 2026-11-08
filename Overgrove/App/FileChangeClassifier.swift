import Foundation

/// What a batch of file system events means for one repository (auto refresh, #119).
struct FileChangeSet: Equatable, Sendable {
    /// Worktrees whose status may have changed (their files, `HEAD`, or `index`).
    var worktrees: Set<GitPath> = []
    /// `refs/` or `packed-refs` changed: branches, tags, or remote-tracking refs moved.
    var refs = false
    /// `worktrees/<id>` appeared, disappeared, or changed its lock or location, or a `HEAD` moved: the worktree list
    /// changed (#416).
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
/// worktree), `refs/` and `packed-refs`, `worktrees/<id>/HEAD|index` (that linked worktree; `HEAD` also the list,
/// #416), `worktrees/<id>` itself and its `gitdir`/`locked` (the list), and `config` (everything, it can change how queries run). Objects, logs,
/// `FETCH_HEAD`, `ORIG_HEAD`, hooks and the rest are ignored, so a fetch or gc does not re-run every status.
struct FileChangeClassifier: Equatable, Sendable {
    struct WatchedWorktree: Equatable, Sendable {
        let path: GitPath
        /// The worktree folder after `realpath(3)`.
        let folder: String
        /// `<common>` for the main worktree, `<common>/worktrees/<id>` for a linked one (canonical).
        let gitDirectory: String
        /// `folder` split once, so each event costs one comparison per worktree.
        fileprivate let folderComponents: [Substring]

        init(path: GitPath, folder: String, gitDirectory: String) {
            self.path = path
            self.folder = folder
            self.gitDirectory = gitDirectory
            folderComponents = FileChangeClassifier.components(folder)
        }
    }

    /// A batch larger than this is treated as a rescan: the work per batch stays bounded however many files a tool
    /// rewrites at once (T15, SEC-T15-17).
    static let maximumEventsPerBatch = 10_000

    let commonDirectory: String
    let worktrees: [WatchedWorktree]
    private let commonComponents: [Substring]
    /// Deepest folder first, so the first match is the innermost worktree (a worktree can sit inside another one).
    private let byDepth: [WatchedWorktree]

    init(commonDirectory: String, worktrees: [WatchedWorktree]) {
        self.commonDirectory = commonDirectory
        self.worktrees = worktrees
        commonComponents = Self.components(commonDirectory)
        byDepth = worktrees.filter { !$0.folderComponents.isEmpty }.sorted {
            ($0.folderComponents.count, $0.folder) > ($1.folderComponents.count, $1.folder)
        }
    }

    /// Folders to give FSEvents: every worktree folder and the shared git directory.
    var watchedPaths: [String] {
        Array(Set(worktrees.map(\.folder) + [commonDirectory])).sorted()
    }

    /// Runs on the stream's queue, off the main actor. Stops early once everything is affected.
    func classify(_ events: [FileEvent]) -> FileChangeSet {
        let everything = everything
        guard events.count <= Self.maximumEventsPerBatch else { return everything }
        var change = FileChangeSet()
        for event in events {
            // A rescan: the system lost the detail, so assume everything under that root changed.
            change.merge(event.needsRescan ? everything : classify(path: event.path))
            if change == everything { break }
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
        if let relative = Self.relative(components, to: commonComponents) {
            return classifyGitDirectory(Array(relative))
        }
        guard
            let (worktree, relative) = byDepth.lazy.compactMap({ worktree in
                Self.relative(components, to: worktree.folderComponents).map { (worktree, $0) }
            }).first
        else { return FileChangeSet() }
        // A linked worktree's `.git` file, or a nested repository's git directory: not this worktree's files.
        if relative.first == ".git" { return FileChangeSet() }
        return FileChangeSet(worktrees: [worktree.path])
    }

    /// `HEAD` also re-reads the worktree list: a switch or a commit on a detached HEAD changes only `HEAD` (and the
    /// index), and the list record (branch, head, detached) is what the sidebar title and the graph's ref set use
    /// (#416). `worktree list` is cheap.
    private func classifyGitDirectory(_ relative: [Substring]) -> FileChangeSet {
        guard let first = relative.first else { return FileChangeSet() }
        switch first {
        case "HEAD", "index":
            guard relative.count == 1, let main = worktrees.first(where: { $0.gitDirectory == commonDirectory })
            else { return FileChangeSet() }
            return FileChangeSet(worktrees: [main.path], worktreeList: first == "HEAD")
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
                return FileChangeSet(worktrees: [linked.path], worktreeList: relative[2] == "HEAD")
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
    fileprivate static func components(_ path: String) -> [Substring] {
        guard path.hasPrefix("/") else { return [] }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains(where: { $0 == "." || $0 == ".." }) else { return [] }
        return parts
    }

    /// The components below `root` (empty for the root itself), or `nil` when the path is not inside it.
    private static func relative(_ components: [Substring], to root: [Substring]) -> ArraySlice<Substring>? {
        guard !root.isEmpty, components.count >= root.count, components.starts(with: root) else { return nil }
        return components.dropFirst(root.count)
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
