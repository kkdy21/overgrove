import Foundation

/// The base branches S-11 offers, and the one it starts with.
struct ComparisonBases: Sendable, Equatable {
    /// Local and remote-tracking branches, in `for-each-ref` order.
    let all: [FullRefName]
    /// `origin/HEAD`'s target, else `main`, else `master` (`WorktreeComparison.defaultBase`).
    let preferred: FullRefName?
}

/// What S-11 needs from `RepositoryService` (#157): the comparison, one file's patch, and the base branches (#158).
protocol ComparisonLoading: Sendable {
    func bases(of repository: Repository) async -> ComparisonBases
    func compare(_ repository: Repository, worktree: GitPath, base: FullRefName?, includeUncommitted: Bool) async
        -> Result<WorktreeComparison, ComparisonError>
    func patch(
        _ repository: Repository, worktree: GitPath, base: FullRefName, file: GitPath, originalPath: GitPath?,
        includeUncommitted: Bool
    ) async -> DiffLoadResult
}

/// The app's loader over the shared `RepositoryService`. The service verifies the worktree and runs the comparison
/// commands with its safety context (#157); this only maps results for the screen.
struct LiveComparisonLoader: ComparisonLoading {
    let services: @Sendable () async throws -> (GitClient, RepositoryService)

    static let live = LiveComparisonLoader(services: { try await LiveGitClient.shared.services() })

    func bases(of repository: Repository) async -> ComparisonBases {
        guard let (_, service) = try? await services(),
            let refs = await service.cachedOverview(of: repository)?.refs
        else { return ComparisonBases(all: [], preferred: nil) }
        return ComparisonBases(
            all: refs.branches.compactMap { FullRefName($0.fullName) },
            preferred: WorktreeComparison.defaultBase(in: refs))
    }

    func compare(_ repository: Repository, worktree: GitPath, base: FullRefName?, includeUncommitted: Bool) async
        -> Result<WorktreeComparison, ComparisonError>
    {
        guard let (_, service) = try? await services() else {
            return .failure(.git(.executableNotFound(path: "git")))
        }
        return await service.compare(
            repository, worktree: worktree, base: base, includeWorkingTree: includeUncommitted)
    }

    func patch(
        _ repository: Repository, worktree: GitPath, base: FullRefName, file: GitPath, originalPath: GitPath?,
        includeUncommitted: Bool
    ) async -> DiffLoadResult {
        guard file.isRepresentable, originalPath?.isRepresentable ?? true else {
            return .unavailable("This path is not valid UTF-8, so Overgrove cannot show its diff.")
        }
        guard let (_, service) = try? await services() else {
            return .unavailable(GitError.executableNotFound(path: "git").message)
        }
        switch await service.comparePatch(
            repository, worktree: worktree, base: base, file: file, originalPath: originalPath,
            includeWorkingTree: includeUncommitted)
        {
        case .success(let patch):
            do {
                return .patch(try PatchParser.parse(patch.patch, truncated: patch.isTruncated))
            } catch {
                return .unavailable("Overgrove could not read this diff.")
            }
        case .failure(let error):
            return .unavailable(PathValidator.displayable(error.message))
        }
    }
}
