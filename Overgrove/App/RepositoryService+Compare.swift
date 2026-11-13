import Foundation

/// The cache key of a base comparison (#157, overview.md §5): the worktree, the base and its tip, HEAD and the local
/// branch it is on (`nil` when detached: ahead/behind is counted only on a branch, #427), and, when
/// the working tree is included, the time of the status query that the untracked list and the uncommitted changes
/// belong to. Any of these changing makes a new entry; old ones age out of the bounded cache.
struct ComparisonKey: Sendable, Hashable {
    let repositoryID: String
    let worktree: GitPath
    let base: FullRefName
    let baseTip: ObjectID
    let head: ObjectID?
    let localBranch: FullRefName?
    let includesWorkingTree: Bool
    let statusQueried: ContinuousClock.Instant?
}

/// Comparing a worktree with its base branch (#157): files and commits since the merge-base, like a pull request.
extension RepositoryService {
    /// Compares `worktree` with `base` (default: `WorktreeComparison.defaultBase(in:)`). The worktree must be loaded:
    /// the comparison uses the cached overview's refs and status, loading the repository first when nothing is
    /// cached. Commands run only after the same checks as `status` (`prepare`), with that worktree's safety context.
    func compare(
        _ repository: Repository,
        worktree path: GitPath,
        base: FullRefName? = nil,
        includeWorkingTree: Bool
    ) async -> Result<WorktreeComparison, ComparisonError> {
        let target: Target
        switch await comparisonTarget(repository, worktree: path, base: base) {
        case .success(let value): target = value
        case .failure(let error): return .failure(error)
        }
        let key = ComparisonKey(
            repositoryID: repository.id, worktree: path, base: target.base, baseTip: target.baseTip,
            head: target.state.headCommit, localBranch: target.localBranch, includesWorkingTree: includeWorkingTree,
            statusQueried: includeWorkingTree ? target.statusQueried : nil)
        if let cached = comparisons.value(for: key) { return .success(cached) }

        let result = await Self.loadComparison(target, includeWorkingTree: includeWorkingTree, makeContext(repository))
        if case .success(let comparison) = result { comparisons.insert(comparison, for: key) }
        return result
    }

    /// The refs S-11 offers as bases, from the cached overview. The cache is shared by every window and dropped when a
    /// refresh fails or the repository is pushed out of it, so the repository is read first when it is gone, as
    /// `compare` does (#415). `nil` when that read fails or is superseded.
    func comparisonRefs(_ repository: Repository) async -> RefParser.Listing? {
        if cachedOverview(of: repository) == nil {
            guard let refresh = await refresh(repository, trigger: .user), case .success = refresh.result else {
                return nil
            }
        }
        return cachedOverview(of: repository)?.refs
    }

    /// One file's patch in the comparison. Not cached: patches are read one file at a time.
    func comparePatch(
        _ repository: Repository,
        worktree path: GitPath,
        base: FullRefName,
        file: GitPath,
        originalPath: GitPath? = nil,
        includeWorkingTree: Bool
    ) async -> Result<ComparisonPatch, ComparisonError> {
        let target: Target
        switch await comparisonTarget(repository, worktree: path, base: base) {
        case .success(let value): target = value
        case .failure(let error): return .failure(error)
        }
        let command = ReadOnlyGitCommand.comparePatch(
            base: target.base, path: file, originalPath: originalPath, includeWorkingTree: includeWorkingTree)
        return await Self.run(target, makeContext(repository)) { folder, safety, client in
            let output = try await client.run(command, in: folder, safety: safety)
            return ComparisonPatch(patch: output.stdout, isTruncated: output.isTruncated)
        }
    }

    /// What a comparison is about, from the cached overview.
    struct Target: Sendable {
        let worktree: Worktree
        let state: WorkingState
        let statusQueried: ContinuousClock.Instant?
        let base: FullRefName
        let baseTip: ObjectID

        /// The local branch HEAD is on, `nil` when detached: ahead/behind is counted against it.
        var localBranch: FullRefName? {
            if case .branch(let name) = state.head { FullRefName("refs/heads/\(name)") } else { nil }
        }
    }

    private func comparisonTarget(
        _ repository: Repository, worktree path: GitPath, base: FullRefName?
    ) async -> Result<Target, ComparisonError> {
        if cachedState(of: repository, worktree: path) == nil {
            guard let refresh = await refresh(repository, trigger: .worktreeSelected(path)) else {
                return .failure(.git(.cancelled))
            }
            if case .failure(let error) = refresh.result { return .failure(.git(error)) }
        }
        guard let (overview, statusQueried) = cachedState(of: repository, worktree: path) else {
            return .failure(.git(.cancelled))
        }
        guard let entry = overview.entries.first(where: { $0.worktree.path == path }),
            case .loaded(let state) = entry.status
        else { return .failure(.worktreeNotQueried) }
        guard let base = base ?? WorktreeComparison.defaultBase(in: overview.refs) else {
            return .failure(.noBaseBranch)
        }
        // A branch of a tree or blob is no base (#559).
        guard let tip = overview.refs.branches.first(where: { $0.fullName == base.value })?.commit else {
            return .failure(.baseNotFound(base))
        }
        return .success(
            Target(worktree: entry.worktree, state: state, statusQueried: statusQueried, base: base, baseTip: tip))
    }

    /// Non-isolated: the comparison's git commands run in parallel without queueing on the actor.
    private static func loadComparison(
        _ target: Target,
        includeWorkingTree: Bool,
        _ context: Context
    ) async -> Result<WorktreeComparison, ComparisonError> {
        let base = target.base
        let localBranch = target.localBranch
        return await run(target, context) { folder, safety, client in
            async let files = client.run(
                .compareFiles(base: base, includeWorkingTree: includeWorkingTree), in: folder, safety: safety)
            async let commits = client.run(
                .commitsAhead(base: base, limit: WorktreeComparison.commitLimit), in: folder, safety: safety)
            async let counts = aheadBehind(localBranch, base: base, in: folder, safety: safety, client: client)
            let (filesOutput, commitsOutput) = try await (files, commits)
            let fileList = try NumstatParser.parseCommitFiles(filesOutput.stdout, truncated: filesOutput.isTruncated)
            let page = try LogParser.parseGraph(commitsOutput.stdout, truncated: commitsOutput.isTruncated)
            return WorktreeComparison(
                base: base, baseTip: target.baseTip, head: target.state.headCommit,
                includesWorkingTree: includeWorkingTree, files: fileList.files, isFileListPartial: fileList.isPartial,
                untracked: includeWorkingTree ? target.state.untracked.map(\.path) : [], commits: page.commits,
                isCommitListPartial: page.isPartial || page.commits.count >= WorktreeComparison.commitLimit,
                counts: try await counts)
        }
    }

    private static func aheadBehind(
        _ local: FullRefName?, base: FullRefName, in folder: URL, safety: RepoSafetyContext, client: GitClient
    ) async throws -> RevListParser.Counts? {
        guard let local else { return nil }
        let output = try await client.run(.aheadBehind(local: local, upstream: base), in: folder, safety: safety)
        return try RevListParser.parse(output.stdout)
    }

    /// Runs `body` in the worktree after the same checks as `status`, mapping failures.
    private static func run<Value: Sendable>(
        _ target: Target,
        _ context: Context,
        _ body: @Sendable (URL, RepoSafetyContext, GitClient) async throws -> Value
    ) async -> Result<Value, ComparisonError> {
        let listed = URL(fileURLWithPath: target.worktree.path.display, isDirectory: true)
        guard let folder = PathValidator.canonical(listed) else {
            return .failure(.git(.worktreeMissing(path: listed.path)))
        }
        switch await prepare(target.worktree, at: folder, context) {
        case .refused(.failed(let error)):
            return .failure(.git(error))
        case .refused(.notQueried(.inspectionBlocked(let reason))):
            return .failure(.git(.configInspectionFailed(reason: reason)))
        case .refused:
            return .failure(.worktreeNotQueried)
        case .ready(let folder, let safety):
            do {
                return .success(try await body(folder, safety, context.client))
            } catch let error as GitError {
                return .failure(.git(error))
            } catch let error as ParseError {
                return .failure(.git(GitError(error)))
            } catch {
                return .failure(.git(.cancelled))
            }
        }
    }
}
