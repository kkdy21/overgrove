import Foundation

/// The refs a graph page was read with (ADR-0010 §3, overview.md §5): every branch, remote-tracking branch, and tag
/// tip, and every worktree's HEAD: the namespaces `graphPage` walks (#308). Pages continue only within one ref set;
/// when it changes, the graph starts over.
///
/// The match is by namespace. A ref the parser skips (`RefParser.Listing.skippedRecords`, e.g. a non-UTF-8 name) or
/// one past a truncated listing is still walked but not in the key, so moving only that ref does not invalidate
/// cached pages (security review of #308, low: display only).
///
/// The exact sorted list is the identity, not a hash of it, so two different ref sets can never share cached pages.
struct GraphRefSet: Sendable, Hashable {
    let tips: [String]

    init(refs: RefParser.Listing, worktrees: [Worktree]) {
        var tips = refs.branches.map { "\($0.fullName) \($0.target.hex)" }
        tips += refs.tags.map { "\($0.fullName) \($0.target.hex)" }
        tips += worktrees.compactMap { worktree in worktree.head.map { "HEAD \(worktree.path.display) \($0.hex)" } }
        self.tips = tips.sorted()
    }
}

/// The graph page cache key: repository, ref set, and page bounds.
struct GraphPageKey: Sendable, Hashable {
    let repositoryID: String
    let refSet: GraphRefSet
    let skip: Int
    let limit: Int
}

/// One page of the commit graph and what it was read with.
struct GraphPageSnapshot: Sendable, Equatable {
    let commits: [CommitNode]
    /// The output was cut at the size limit: later pages would not continue it exactly.
    let isPartial: Bool
    let refSet: GraphRefSet
    let refs: RefParser.Listing
    let worktrees: [Worktree]
}

/// Commit graph pages (#68, ADR-0010 §3). Paging is `--skip`/`-n` (git-command-catalog.md §3) until #89 decides
/// between that and streaming; `GraphLoading` keeps the choice behind one interface.
extension RepositoryService {
    /// Commits `skip ..< skip + limit` of `log --date-order` over branches, remote-tracking refs, tags, and worktree
    /// HEADs (the refs `GraphRefSet` keys on, #308), with the refs of the cached
    /// overview (loading it first when nothing is cached). Pages are cached by ref set; ⌘R and `forget` drop them.
    func graphPage(_ repository: Repository, skip: Int, limit: Int) async -> Result<GraphPageSnapshot, GitError> {
        if cachedOverview(of: repository) == nil {
            guard let refresh = await refresh(repository, trigger: .user) else { return .failure(.cancelled) }
            if case .failure(let error) = refresh.result { return .failure(error) }
        }
        guard let overview = cachedOverview(of: repository) else { return .failure(.cancelled) }
        let worktrees = overview.entries.map(\.worktree)
        let refSet = GraphRefSet(refs: overview.refs, worktrees: worktrees)
        let key = GraphPageKey(repositoryID: repository.id, refSet: refSet, skip: skip, limit: limit)
        func snapshot(_ page: LogParser.GraphPage) -> GraphPageSnapshot {
            GraphPageSnapshot(
                commits: page.commits, isPartial: page.isPartial, refSet: refSet, refs: overview.refs,
                worktrees: worktrees)
        }
        if let cached = graphPages.value(for: key) { return .success(snapshot(cached)) }

        switch await Self.readGraphPage(repository, skip: skip, limit: limit, makeContext(repository)) {
        case .success(let page):
            graphPages.insert(page, for: key)
            return .success(snapshot(page))
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Non-isolated: the git command runs without holding the actor.
    private static func readGraphPage(
        _ repository: Repository, skip: Int, limit: Int, _ context: Context
    ) async -> Result<LogParser.GraphPage, GitError> {
        let directory = repository.rootURL ?? repository.commonGitDirectoryURL
        do {
            let inspection = try await inspect(directory, probe: nil, context)
            guard let safety = inspection.safetyContext else {
                return .failure(.configInspectionFailed(reason: inspection.report.blockingReason ?? ""))
            }
            let output = try await context.client.run(
                .graphPage(skip: skip, limit: limit), in: directory, safety: safety)
            return .success(try LogParser.parseGraph(output.stdout, truncated: output.isTruncated))
        } catch let error as GitError {
            return .failure(error)
        } catch let error as ParseError {
            return .failure(GitError(error))
        } catch {
            return .failure(.cancelled)
        }
    }
}
