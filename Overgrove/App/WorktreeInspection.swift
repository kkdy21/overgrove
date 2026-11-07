import Foundation

/// What S-05 shows about one worktree's safety (security-review.md §6), read when the `Worktree` segment opens.
struct WorktreeInspection: Sendable, Equatable {
    /// `nil` when the configuration could not be read; `failure` says why.
    let inspection: RepoConfigInspection?
    let failure: String?
    let inspectedAt: Date
    let gitVersion: GitVersion?
    /// The arguments every query carries (`GitEnvironment.commonArguments`), so the ✓ rows reflect what really runs.
    let commonArguments: [String]
    /// What the catalog passes to `git diff` for a worktree file, for the external diff / textconv row.
    let diffArguments: [String]
    /// Executable hook files that are not `.sample` (security-review.md §6, "Hooks disabled" ⚠), as display lines:
    /// `hooks/pre-commit`, `+3 more`, or a note that `hooks` is a link. Names only, escaped.
    let hookExecutables: [String]
    /// The real location when the worktree path goes through a symbolic link (T14); `nil` otherwise.
    let realPath: String?
}

/// Reads a worktree's configuration for S-05. Only `configList`, a command allowed before inspection, runs.
protocol WorktreeInspecting: Sendable {
    func inspect(_ worktree: Worktree, of repository: Repository) async -> WorktreeInspection
}

/// The app's inspector. Call it only for worktrees `RepositoryService` already verified belong to the repository
/// (`.loaded` or `.notQueried(.inspectionBlocked)`). It runs in the worktree's canonical path and checks it belongs
/// again (probe) before reading the configuration.
///
/// TODO(#240): read the inspection RepositoryService already made for this worktree (`RepositoryOverview.Entry`)
/// instead of running `configList` again.
struct LiveWorktreeInspector: WorktreeInspecting {
    let client: @Sendable () async throws -> GitClient
    var now: @Sendable () -> Date = { Date() }

    static let live = LiveWorktreeInspector(client: { try await LiveGitClient.shared.client() })

    /// Hook names listed at most; a forged repository could hold many files.
    static let maximumHookNames = 20

    func inspect(_ worktree: Worktree, of repository: Repository) async -> WorktreeInspection {
        let diffArguments =
            (try? ReadOnlyGitCommand.worktreeDiff(path: GitPath("file"), staged: false)
                .subcommandArguments()) ?? []
        let hooks = Self.hookExecutables(in: repository.commonGitDirectoryURL)
        let listed = URL(fileURLWithPath: worktree.path.display, isDirectory: true)
        let real = PathValidator.canonical(listed)
        let realPath = real.flatMap { $0.path == PathValidator.lexicallyNormalized(listed.path) ? nil : $0.path }

        func result(_ inspection: RepoConfigInspection?, failure: String?, version: GitVersion?) -> WorktreeInspection {
            WorktreeInspection(
                inspection: inspection, failure: failure, inspectedAt: now(), gitVersion: version,
                commonArguments: GitEnvironment.commonArguments, diffArguments: diffArguments,
                hookExecutables: hooks, realPath: realPath)
        }

        guard worktree.path.isRepresentable, let directory = real else {
            return result(nil, failure: "The worktree folder could not be found.", version: nil)
        }
        let client: GitClient
        do {
            client = try await self.client()
        } catch {
            return result(nil, failure: GitError.executableNotFound(path: "git").message, version: nil)
        }
        let version = client.environment.version
        do {
            // The folder was verified when the list loaded, but links can change since. Check again right before
            // reading its configuration, with the same rule as RepositoryService (security review of #67, T14).
            let probe = try await client.run(.probeRepository, in: directory, safety: .preInspection)
            guard let reported = try? ProbeParser.parse(probe.stdout),
                Self.belongs(directory, probe: reported, commonDirectory: repository.commonGitDirectoryURL)
            else {
                return result(
                    nil, failure: "This folder no longer matches the repository, so it was not inspected.",
                    version: version)
            }
            let output = try await client.run(.configList, in: directory, safety: .preInspection)
            let listing = try ConfigParser.parse(output.stdout, truncated: output.isTruncated)
            return result(RepoConfigInspector.inspect(listing), failure: nil, version: version)
        } catch let error as GitError {
            return result(nil, failure: PathValidator.displayable(error.message), version: version)
        } catch {
            return result(
                nil, failure: GitError.parseFailed(parser: "ConfigParser", offset: 0).message, version: version)
        }
    }

    /// git reports this folder itself as the worktree, the shared directory matches, and the folder's `.git` leads
    /// there directly (main worktree) or as a linked worktree whose administrative entry points back.
    static func belongs(_ directory: URL, probe: RepositoryProbe, commonDirectory: URL) -> Bool {
        guard let common = PathValidator.canonical(commonDirectory),
            PathValidator.canonical(probe.topLevel)?.path == directory.path,
            PathValidator.canonical(probe.commonDirectory)?.path == common.path
        else { return false }
        if PathValidator.gitDirectory(of: directory)?.path == common.path { return true }
        if case .linked = PathValidator.checkLinkedWorktree(root: directory, commonGitDirectory: common) { return true }
        return false
    }

    /// Directory entries read at most while looking for hooks; a forged repository could hold millions.
    static let maximumHookScan = 1_000

    /// Executable files in `<common dir>/hooks` that are not `.sample`. git would run them without
    /// `core.hooksPath=/dev/null`. Only names are read, never contents. A `hooks` that is itself a link is reported
    /// as such and not followed. A link inside counts as executable whatever its target (macOS gives links mode
    /// 0755): over-reporting is the safe side.
    static func hookExecutables(in commonDirectory: URL) -> [String] {
        let hooks = commonDirectory.appendingPathComponent("hooks", isDirectory: true)
        var info = stat()
        guard lstat(hooks.path, &info) == 0 else { return [] }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: break
        case S_IFLNK: return ["hooks (a link, not followed)"]
        default: return []
        }
        guard let directory = opendir(hooks.path) else { return [] }
        defer { closedir(directory) }
        var names: [String] = []
        var scanned = 0
        while scanned < maximumHookScan, let entry = readdir(directory) {
            scanned += 1
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            guard name != ".", name != "..", !name.hasSuffix(".sample") else { continue }
            var file = stat()
            // lstat: a link is reported as itself, not followed.
            guard lstat(hooks.appendingPathComponent(name).path, &file) == 0 else { continue }
            let type = file.st_mode & S_IFMT
            if (type == S_IFREG || type == S_IFLNK) && file.st_mode & 0o111 != 0 { names.append("hooks/" + name) }
        }
        names.sort()
        var shown = names.prefix(maximumHookNames).map(PathValidator.displayable)
        let more = names.count - shown.count
        if more > 0 { shown.append("+\(more) more") }
        if scanned >= maximumHookScan { shown.append("(stopped after \(maximumHookScan) entries)") }
        return shown
    }
}
