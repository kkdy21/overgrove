import Foundation

/// Per-worktree checks before `status` runs (security review of #221) and the cached configuration inspection (#88).
extension RepositoryService {
    /// One worktree's status. Errors stay with that worktree, except cancellation, which ends the whole load.
    ///
    /// Worktree paths come from files the repository controls (`.git/worktrees/<id>/gitdir`), so each one is treated
    /// as untrusted: it must belong to this repository (same git common directory, probed every time), and its own
    /// configuration is inspected (a linked worktree can have `config.worktree`) before `status` runs with that
    /// worktree's safety context. Both checks use the commands allowed before inspection.
    static func status(of worktree: Worktree, _ context: Context) async -> RepositoryOverview.Status {
        let directory = URL(fileURLWithPath: worktree.path.display, isDirectory: true)
        do {
            let output: GitOutput
            do {
                output = try await context.client.run(.probeRepository, in: directory, safety: .preInspection)
            } catch GitError.launchFailed(errno: ENOENT) {
                // The probe runs in a folder that may not be a repository yet, so GitClient reports a missing folder
                // as a launch failure. Here it is a worktree that vanished after the list was read.
                return .failed(.worktreeMissing(path: directory.path))
            }
            guard let probe = try? ProbeParser.parse(output.stdout),
                isSameDirectory(probe.commonDirectory, context.repository.commonGitDirectoryURL)
            else { return .notQueried(.foreignRepository) }

            let inspection = try await inspect(directory, probe: probe, context)
            guard let safety = inspection.safetyContext else {
                return .notQueried(.inspectionBlocked(inspection.report.blockingReason ?? ""))
            }

            let status = try await context.client.run(.status, in: directory, safety: safety)
            return .loaded(try StatusParser.parse(status.stdout, truncated: status.isTruncated))
        } catch let error as GitError {
            return .failed(error)
        } catch let error as ParseError {
            return .failed(GitError(error))
        } catch {
            return .failed(.cancelled)
        }
    }

    /// The configuration inspection for `directory`, from the cache while none of the files git reads for it has
    /// changed (overview.md §5). The fingerprint is taken before `config --list` runs, so a change made while it runs
    /// still invalidates the entry next time.
    static func inspect(
        _ directory: URL,
        probe: RepositoryProbe?,
        _ context: Context
    ) async throws -> RepoConfigInspection {
        let key = inspectionPrefix(context.repository) + directory.path
        let fingerprint = configurationFiles(
            of: directory, probe: probe, commonDirectory: context.repository.commonGitDirectoryURL
        ).map(RepoConfigInspectionCache.Fingerprint.make)
        if let fingerprint, let cached = await context.inspections?.inspection(for: key, fingerprint: fingerprint) {
            return cached
        }
        let output = try await context.client.run(.configList, in: directory, safety: .preInspection)
        let inspection = RepoConfigInspector.inspect(
            try ConfigParser.parse(output.stdout, truncated: output.isTruncated))
        if let fingerprint {
            await context.inspections?.store(inspection, for: key, fingerprint: fingerprint)
        }
        return inspection
    }

    /// The files whose contents decide `directory`'s configuration: the shared `config`, both `config.worktree`
    /// files, the worktree's `.git` entry and its `commondir`. `nil` (do not cache) when git's view of the directory
    /// cannot be confirmed: the probed worktree root is another folder, or the git directory cannot be found.
    ///
    /// Repository-controlled includes make the inspection uncacheable (`RepoConfigInspection.isCacheable`).
    static func configurationFiles(of directory: URL, probe: RepositoryProbe?, commonDirectory: URL) -> [URL]? {
        let gitDirectory: URL
        if isSameDirectory(directory, commonDirectory) {
            gitDirectory = commonDirectory  // a bare repository
        } else {
            if let probe, !isSameDirectory(probe.topLevel, directory) { return nil }
            guard let found = PathValidator.gitDirectory(of: directory) else { return nil }
            gitDirectory = found
        }
        return [
            commonDirectory.appendingPathComponent("config"),
            commonDirectory.appendingPathComponent("config.worktree"),
            gitDirectory.appendingPathComponent("config.worktree"),
            gitDirectory.appendingPathComponent("commondir"),
            directory.appendingPathComponent(".git"),
        ]
    }

    /// Inspection cache keys of one repository start with this, so ⌘R and `forget` drop them together.
    static func inspectionPrefix(_ repository: Repository) -> String {
        repository.id + "\u{0}"
    }

    /// Compared after `realpath(3)` (PathValidator), so a symbolic link cannot make two folders look alike or apart.
    static func isSameDirectory(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhs = PathValidator.canonical(lhs), let rhs = PathValidator.canonical(rhs) else { return false }
        return lhs.path == rhs.path
    }
}
