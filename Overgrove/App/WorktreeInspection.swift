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
    /// Executable hook files that are not `.sample` (security-review.md §6, "Hooks disabled" ⚠). Names only.
    let hookExecutables: [String]
    /// The real location when the worktree path goes through a symbolic link (T14); `nil` otherwise.
    let realPath: String?
}

/// Reads a worktree's configuration for S-05. Only `configList`, a command allowed before inspection, runs.
protocol WorktreeInspecting: Sendable {
    func inspect(_ worktree: Worktree, of repository: Repository) async -> WorktreeInspection
}

/// The app's inspector. Call it only for worktrees `RepositoryService` already verified belong to the repository
/// (`.loaded` or `.notQueried(.inspectionBlocked)`); it runs in the worktree's canonical path.
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

    /// Executable files in `<common dir>/hooks` that are not `.sample`. git would run them without
    /// `core.hooksPath=/dev/null`. Only names are read, never contents.
    static func hookExecutables(in commonDirectory: URL) -> [String] {
        let hooks = commonDirectory.appendingPathComponent("hooks", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: hooks.path) else { return [] }
        let executables = names.sorted().filter { name in
            guard !name.hasSuffix(".sample") else { return false }
            var info = stat()
            let path = hooks.appendingPathComponent(name).path
            // lstat: a link is reported as itself, not followed.
            guard lstat(path, &info) == 0 else { return false }
            let type = info.st_mode & S_IFMT
            return (type == S_IFREG || type == S_IFLNK) && info.st_mode & 0o111 != 0
        }
        return Array(executables.prefix(maximumHookNames)).map(PathValidator.displayable)
    }
}
