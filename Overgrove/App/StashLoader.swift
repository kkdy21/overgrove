import Foundation

/// The outcome of reading a stash's files for S-04.
enum StashFilesResult: Sendable, Equatable {
    case files(StashDetail)
    case unavailable(String)
}

/// Reads a stash's files and one file's patch (S-04, #71). Stashes are addressed by OID only.
protocol StashLoading: Sendable {
    func files(of stash: Stash, in repository: Repository, worktree: Worktree?) async -> StashFilesResult
    func patch(of stash: Stash, file: FileStat, in repository: Repository, worktree: Worktree?) async
        -> DiffLoadResult
}

/// The app's loader. Stash commands run in the main worktree, or for a bare repository in the given verified worktree
/// (`stash show` needs a work tree, #222). Before running, that folder is checked again and its configuration
/// inspected (`LiveWorktreeInspector.verifiedInspection`), so the commands run with its safety context.
struct LiveStashLoader: StashLoading {
    let client: @Sendable () async throws -> GitClient

    static let live = LiveStashLoader(client: { try await LiveGitClient.shared.client() })

    func files(of stash: Stash, in repository: Repository, worktree: Worktree?) async -> StashFilesResult {
        await run(repository, worktree: worktree, unavailable: StashFilesResult.unavailable) { client, folder, safety in
            // Which files came from the untracked part: the third parent's tree (parsing-spec.md §8.2).
            var untracked = Set<GitPath>()
            if stash.includesUntracked, stash.parents.count >= 3 {
                let output = try await client.run(
                    .commitFiles(stash.parents[2], firstParent: nil), in: folder, safety: safety)
                untracked = Set(
                    try NumstatParser.parseCommitFiles(output.stdout, truncated: output.isTruncated).files.map(\.path))
            }
            let output = try await client.run(.stashFiles(stash.oid), in: folder, safety: safety)
            let files = try NumstatParser.parseStashFiles(
                output.stdout, untrackedPaths: untracked, truncated: output.isTruncated)
            return .files(StashDetail(stash: stash, files: files.files, isPartial: files.isPartial))
        }
    }

    func patch(of stash: Stash, file: FileStat, in repository: Repository, worktree: Worktree?) async
        -> DiffLoadResult
    {
        guard file.path.isRepresentable else {
            return .unavailable("This path is not valid UTF-8, so Overgrove cannot show its diff.")
        }
        return await run(repository, worktree: worktree, unavailable: DiffLoadResult.unavailable) {
            client, folder, safety in
            let output = try await client.run(
                .stashPatch(
                    stash.oid, path: file.path, originalPath: file.originalPath, fromUntracked: file.isFromUntracked),
                in: folder,
                safety: safety)
            return .patch(try PatchParser.parse(output.stdout, truncated: output.isTruncated))
        }
    }

    private func run<Result>(
        _ repository: Repository, worktree: Worktree?, unavailable: (String) -> Result,
        _ body: (GitClient, URL, RepoSafetyContext) async throws -> Result
    ) async -> Result {
        let listed = repository.rootURL ?? worktree.map { URL(fileURLWithPath: $0.path.display, isDirectory: true) }
        guard let listed, let folder = PathValidator.canonical(listed) else {
            return unavailable("No worktree is available to read this stash.")
        }
        do {
            let client = try await self.client()
            guard
                let inspection = try await LiveWorktreeInspector.verifiedInspection(
                    at: folder, of: repository, client: client)
            else { return unavailable(LiveWorktreeInspector.noLongerMatches) }
            guard let safety = inspection.safetyContext else {
                return unavailable(
                    "Overgrove stopped querying this repository for safety. "
                        + PathValidator.displayable(inspection.report.blockingReason ?? ""))
            }
            return try await body(client, folder, safety)
        } catch let error as GitError {
            return unavailable(PathValidator.displayable(error.message))
        } catch is ParseError {
            return unavailable("Overgrove could not read this stash.")
        } catch {
            return unavailable(GitError.cancelled.message)
        }
    }
}
