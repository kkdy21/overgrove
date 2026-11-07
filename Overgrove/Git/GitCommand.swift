/// The only git commands Overgrove can run (git-command-catalog.md §3–§4, threat T13).
///
/// Write commands (push, pull, reset, clean, checkout, commit, stash apply/pop/drop, …) intentionally have no case.
/// Cases define only the subcommand part; `GitClient` prepends the common safety arguments
/// (git-command-catalog.md §1). Arguments are validated types, never raw strings (T9).
enum ReadOnlyGitCommand: Sendable, Hashable {
    case version
    /// Registration probe that also works in a bare repository and inside a git directory (no `--show-toplevel`,
    /// #222). Run first; `probeRepository` follows only inside a work tree.
    case probeGitDirectory
    case probeRepository
    case configList
    case worktreeList
    case status
    case refs
    case aheadBehind(local: FullRefName, upstream: FullRefName)
    case stashList
    case stashFiles(ObjectID)
    /// Patch of one file in a stash. Tracked changes are diffed against the stash's base (`^1`); files from the
    /// untracked part (`stash -u`) come from the third parent (`^3`). `git stash show` accepts no pathspec.
    case stashPatch(ObjectID, path: GitPath, fromUntracked: Bool)
    case graphPage(skip: Int, limit: Int)
    case commitMeta(ObjectID)
    /// `firstParent` is set for merge commits, which are compared with their first parent.
    case commitFiles(ObjectID, firstParent: ObjectID?)
    case commitPatch(ObjectID, parent: ObjectID?, path: GitPath)
    case worktreeDiff(path: GitPath, staged: Bool)
    /// Diff of an untracked file against /dev/null. Only a `WorktreeFile` (checked by `PathValidator`) is accepted.
    case untrackedPreview(WorktreeFile)
    case fileHistory(path: GitPath, limit: Int)
    /// Files changed in the worktree since it branched off `base` (the merge-base, like a pull request's "Files
    /// changed", #157). With `includeWorkingTree`, uncommitted tracked changes count too; untracked files come from
    /// `status`.
    case compareFiles(base: FullRefName, includeWorkingTree: Bool)
    /// Patch of one file in the same comparison.
    case comparePatch(base: FullRefName, path: GitPath, includeWorkingTree: Bool)
    /// Commits on HEAD that `base` does not have (`<base>..HEAD`), newest first.
    case commitsAhead(base: FullRefName, limit: Int)

    enum Location: Sendable, Equatable {
        /// An app-owned temporary directory outside any repository.
        case neutral
        /// The folder the user picked (before it is known to be a repository).
        case registeredPath
        case repository
        case worktree
    }

    /// Graph and file history (parsing-spec.md §5.1). The last field lists `Co-authored-by` trailer values (matched
    /// case-insensitively, folded lines unfolded) separated by U+001F (#160). No `%G` placeholder: those run
    /// `gpg.program` (T7).
    static let logFormat =
        "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x00%(trailers:key=Co-authored-by,valueonly,unfold,separator=%x1f)"

    /// Subcommand arguments. Throws `GitError.invalidArgument` for values that cannot be passed losslessly.
    func subcommandArguments() throws -> [String] {
        switch self {
        case .version:
            return ["version"]
        case .probeGitDirectory:
            return [
                "rev-parse", "--path-format=absolute", "--git-common-dir", "--absolute-git-dir", "--is-bare-repository",
                "--is-inside-work-tree",
            ]
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
                "--format=%(refname)%00%(objectname)%00%(*objectname)%00%(upstream)%00%(HEAD)%00%(committerdate:unix)%00%(symref)%00%(upstream:track,nobracket)",
                "refs/heads", "refs/remotes", "refs/tags",
            ]
        case .aheadBehind(let local, let upstream):
            return ["rev-list", "--left-right", "--count", "--end-of-options", "\(upstream.value)...\(local.value)"]
        case .stashList:
            // The reflog walk `git stash list` runs internally (same bytes), but without its work-tree requirement,
            // so it also works in a bare repository (#222). `--ignore-missing`: no `refs/stash` is an empty list.
            return ["log", "-g", "-z", "--ignore-missing", "--format=%gd%x00%H%x00%gs%x00%ct", "refs/stash", "--"]
        case .stashFiles(let oid):
            return [
                "stash", "show", "--include-untracked", "--numstat", "-z", "--no-ext-diff", "--no-textconv",
                "--end-of-options", oid.hex,
            ]
        case .stashPatch(let oid, let path, let fromUntracked):
            // Options (including --root) must come before --end-of-options, revisions after it.
            let options =
                ["diff-tree", "-p", "-M", "--no-ext-diff", "--no-textconv"] + (fromUntracked ? ["--root"] : [])
            let revisions = fromUntracked ? ["\(oid.hex)^3"] : ["\(oid.hex)^1", oid.hex]
            return options + ["--end-of-options"] + revisions + (try Self.pathspec(path))
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
            // `--ignore-submodules=dirty` (as in status): for a submodule path git would otherwise run `status` inside
            // the submodule, with the submodule's own filters, which were never inspected (#239, SEC-T4-05).
            return ["diff", "--no-ext-diff", "--no-textconv", "-M", "--ignore-submodules=dirty"]
                + (staged ? ["--cached"] : []) + (try Self.pathspec(path))
        case .untrackedPreview(let file):
            return ["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--", "/dev/null", file.relativePath]
        case .fileHistory(let path, let limit):
            return ["log", "--follow", "-z", Self.logFormat, "-n", String(Self.clampLimit(limit))]
                + (try Self.pathspec(path))
        case .compareFiles(let base, let includeWorkingTree):
            // `--no-abbrev`: `git diff --raw` abbreviates object names, unlike `diff-tree`. `--ignore-submodules=dirty`
            // (as in status): otherwise git runs `status` inside each submodule, whose own filters were never
            // inspected (SEC-T4-05). The trailing `--` keeps a file named like the ref from being read as a path.
            return [
                "diff", "-z", "--raw", "--numstat", "-M", "--no-abbrev", "--no-ext-diff", "--no-textconv",
                "--ignore-submodules=dirty", "--merge-base", "--end-of-options", base.value,
            ] + (includeWorkingTree ? [] : ["HEAD"]) + ["--"]
        case .comparePatch(let base, let path, let includeWorkingTree):
            return [
                "diff", "-p", "-M", "--no-ext-diff", "--no-textconv", "--ignore-submodules=dirty", "--merge-base",
                "--end-of-options", base.value,
            ]
                + (includeWorkingTree ? [] : ["HEAD"]) + (try Self.pathspec(path))
        case .commitsAhead(let base, let limit):
            // `FullRefName` has no `..`, so `<base>..HEAD` is one unambiguous range.
            return [
                "log", "-z", Self.logFormat, "-n", String(Self.clampLimit(limit)), "--end-of-options",
                "\(base.value)..HEAD", "--",
            ]
        }
    }

    /// Commands that read worktree content or history can run repository-configured programs (filters, T4), so they
    /// need the neutralization arguments from `RepoConfigInspector` first. Only these may run before inspection.
    var requiresInspection: Bool {
        switch self {
        case .version, .probeGitDirectory, .probeRepository, .configList: false
        default: true
        }
    }

    var location: Location {
        switch self {
        case .version: .neutral
        case .probeGitDirectory, .probeRepository: .registeredPath
        case .status, .worktreeDiff, .untrackedPreview, .fileHistory, .compareFiles, .comparePatch, .commitsAhead:
            .worktree
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

/// The only command that touches a remote (git-command-catalog.md §4). It writes `refs/remotes/<remote>/*` only.
///
/// What fetch writes is pinned on the command line, because a repository's own configuration could otherwise widen
/// it (#209, T13): a local `remote.<n>.fetch=+refs/heads/*:refs/heads/*` made fetch delete local branches and
/// force-move `main` (with a detached HEAD), and `fetch.pruneTags` deleted local tags.
/// - The refspec is given explicitly, and `--refmap=` stops git from also applying the configured refspecs.
/// - `--no-tags`: no tag is written, so `refs/tags/*` stays the user's (it also overrides `remote.<n>.tagOpt`).
/// - `--prune` then only prunes inside the given refspec's destination, `refs/remotes/<remote>/*`.
enum FetchCommand: Sendable, Hashable {
    case fetch(remote: RemoteName)

    func subcommandArguments() -> [String] {
        switch self {
        case .fetch(let remote):
            [
                "fetch", "--prune", "--no-recurse-submodules", "--progress", "--no-tags",
                "--upload-pack=git-upload-pack", "--refmap=", "--end-of-options", remote.value, refspec,
            ]
        }
    }

    /// The only refspec fetch uses: every branch of the remote into its own remote-tracking namespace.
    var refspec: String {
        switch self {
        case .fetch(let remote): "+refs/heads/*:refs/remotes/\(remote.value)/*"
        }
    }

    /// `-c` overrides placed after the repository's neutralization and fetch authentication, so they win over local
    /// values (git-command-catalog.md §4). The remote name is validated (`[A-Za-z0-9._/-]`), so the key is unambiguous.
    func configurationOverrides() -> [String] {
        switch self {
        case .fetch(let remote):
            [
                "-c", "fetch.pruneTags=false", "-c", "remote.\(remote.value).pruneTags=false",
                "-c", "fetch.writeCommitGraph=false",
                // A bundle URI makes fetch download from another location and write refs/bundles/* (git 2.42+);
                // older git ignores the key (security review of #210).
                "-c", "fetch.bundleURI=",
            ]
        }
    }
}
