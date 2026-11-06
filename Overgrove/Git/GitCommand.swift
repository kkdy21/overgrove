/// The only git commands Overgrove can run (git-command-catalog.md §3–§4, threat T13).
///
/// Write commands (push, pull, reset, clean, checkout, commit, stash apply/pop/drop, …) intentionally have no case.
/// Cases define only the subcommand part; `GitClient` prepends the common safety arguments
/// (git-command-catalog.md §1). Arguments are validated types, never raw strings (T9).
enum ReadOnlyGitCommand: Sendable, Hashable {
    case version
    case probeRepository
    case configList
    case worktreeList
    case status
    case refs
    case aheadBehind(local: FullRefName, upstream: FullRefName)
    case stashList
    case stashFiles(ObjectID)
    case stashPatch(ObjectID, path: GitPath)
    case graphPage(skip: Int, limit: Int)
    case commitMeta(ObjectID)
    /// `firstParent` is set for merge commits, which are compared with their first parent.
    case commitFiles(ObjectID, firstParent: ObjectID?)
    case commitPatch(ObjectID, parent: ObjectID?, path: GitPath)
    case worktreeDiff(path: GitPath, staged: Bool)
    /// Diff of an untracked file against /dev/null. Run only after `PathValidator` placed it inside the worktree.
    case untrackedPreview(path: GitPath)
    case fileHistory(path: GitPath, limit: Int)

    enum Location: Sendable, Equatable {
        /// An app-owned temporary directory outside any repository.
        case neutral
        /// The folder the user picked (before it is known to be a repository).
        case registeredPath
        case repository
        case worktree
    }

    static let logFormat = "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s"

    /// Subcommand arguments. Throws `GitError.invalidArgument` for values that cannot be passed losslessly.
    func subcommandArguments() throws -> [String] {
        switch self {
        case .version:
            return ["version"]
        case .probeRepository:
            return [
                "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir", "--is-bare-repository",
            ]
        case .configList:
            return ["config", "--list", "--show-scope", "-z", "--includes"]
        case .worktreeList:
            return ["worktree", "list", "--porcelain", "-z"]
        case .status:
            return [
                "status", "--porcelain=v2", "-z", "--branch", "--show-stash", "--untracked-files=all",
                "--ignore-submodules=dirty",
            ]
        case .refs:
            return [
                "for-each-ref",
                "--format=%(refname)%00%(objectname)%00%(*objectname)%00%(upstream)%00%(HEAD)%00%(committerdate:unix)%00%(symref)",
                "refs/heads", "refs/remotes", "refs/tags",
            ]
        case .aheadBehind(let local, let upstream):
            return ["rev-list", "--left-right", "--count", "--end-of-options", "\(upstream.value)...\(local.value)"]
        case .stashList:
            return ["stash", "list", "-z", "--format=%gd%x00%H%x00%gs%x00%ct"]
        case .stashFiles(let oid):
            return [
                "stash", "show", "--include-untracked", "--numstat", "-z", "--no-ext-diff", "--no-textconv",
                "--end-of-options", oid.hex,
            ]
        case .stashPatch(let oid, let path):
            return [
                "stash", "show", "-p", "--include-untracked", "--no-ext-diff", "--no-textconv", "--end-of-options",
                oid.hex,
            ] + (try Self.pathspec(path))
        case .graphPage(let skip, let limit):
            return [
                "log", "--exclude=refs/stash", "--all", "--date-order", "-z", Self.logFormat,
                "--skip=\(max(0, skip))", "-n", String(Self.clampLimit(limit)),
            ]
        case .commitMeta(let oid):
            return [
                "log", "-1", "-z", "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%cn%x00%ce%x00%ct%x00%B",
                "--end-of-options", oid.hex,
            ]
        case .commitFiles(let oid, let firstParent):
            return [
                "diff-tree", "-r", "-z", "--raw", "--numstat", "-M", "--no-ext-diff", "--no-textconv",
                "--no-commit-id", "--root", "--end-of-options",
            ] + (firstParent.map { [$0.hex] } ?? []) + [oid.hex]
        case .commitPatch(let oid, let parent, let path):
            return ["diff-tree", "-p", "-M", "--no-ext-diff", "--no-textconv", "--root", "--end-of-options"]
                + (parent.map { [$0.hex] } ?? []) + [oid.hex] + (try Self.pathspec(path))
        case .worktreeDiff(let path, let staged):
            return ["diff", "--no-ext-diff", "--no-textconv", "-M"] + (staged ? ["--cached"] : [])
                + (try Self.pathspec(path))
        case .untrackedPreview(let path):
            guard let argument = path.argument else { throw Self.unrepresentable }
            return ["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--", "/dev/null", argument]
        case .fileHistory(let path, let limit):
            return ["log", "--follow", "-z", Self.logFormat, "-n", String(Self.clampLimit(limit))]
                + (try Self.pathspec(path))
        }
    }

    var location: Location {
        switch self {
        case .version: .neutral
        case .probeRepository: .registeredPath
        case .status, .worktreeDiff, .untrackedPreview, .fileHistory: .worktree
        default: .repository
        }
    }

    /// `git diff --no-index` exits 1 when the files differ, which is the normal case for a preview.
    var acceptedExitCodes: Set<Int32> {
        if case .untrackedPreview = self { return [0, 1] }
        return [0]
    }

    private static let unrepresentable = GitError.invalidArgument(reason: "path is not valid UTF-8")

    private static func pathspec(_ path: GitPath) throws -> [String] {
        guard let arguments = path.pathspecArguments else { throw unrepresentable }
        return arguments
    }

    private static func clampLimit(_ limit: Int) -> Int { min(max(limit, 1), 100_000) }
}

/// The only command that touches a remote (git-command-catalog.md §4). It updates remote-tracking refs only.
enum FetchCommand: Sendable, Hashable {
    case fetch(remote: RemoteName)

    func subcommandArguments() -> [String] {
        switch self {
        case .fetch(let remote):
            [
                "fetch", "--prune", "--no-recurse-submodules", "--progress", "--upload-pack=git-upload-pack",
                "--end-of-options", remote.value,
            ]
        }
    }
}
