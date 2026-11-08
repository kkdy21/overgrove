import Foundation

/// The refs a graph page was read with (ADR-0010 §3, overview.md §5): every branch, remote-tracking branch, and tag
/// tip, and every worktree's HEAD: the namespaces `graphPage` walks (#308). Pages continue only within one ref set;
/// when it changes, the graph starts over.
///
/// The match is by namespace. A ref the parser skips (`RefParser.Listing.skippedRecords`, e.g. a non-UTF-8 name) or
/// one past a truncated ref or worktree listing is still walked but not in the key, so the key cannot see it move.
/// Such a set is therefore never used to cache pages, and `GraphStore` treats every refresh with it as a move and
/// starts over from the first page (`isComplete`, #333). That costs the scroll position in those rare repositories.
///
/// The exact sorted list is the identity, not a hash of it, so two different ref sets can never share cached pages.
struct GraphRefSet: Sendable, Hashable {
    let tips: [String]

    /// Every ref `graphPage` walks is in `tips`: nothing was skipped or cut off. Only then can pages be cached by it.
    static func isComplete(refs: RefParser.Listing, isWorktreeListPartial: Bool) -> Bool {
        refs.skippedRecords == 0 && !refs.isPartial && !isWorktreeListPartial
    }

    init(refs: RefParser.Listing, worktrees: [Worktree]) {
        var tips = refs.branches.map { "\($0.fullName) \($0.target.hex)" }
        tips += refs.tags.map { "\($0.fullName) \($0.target.hex)" }
        tips += worktrees.compactMap { worktree in worktree.head.map { "HEAD \(worktree.path.display) \($0.hex)" } }
        self.tips = tips.sorted()
    }
}

/// The refs a graph page walks and their ref set.
struct GraphRefs: Sendable {
    let refs: RefParser.Listing
    let worktrees: [Worktree]
    let refSet: GraphRefSet

    init(refs: RefParser.Listing, worktrees: [Worktree]) {
        self.refs = refs
        self.worktrees = worktrees
        refSet = GraphRefSet(refs: refs, worktrees: worktrees)
    }
}

/// Refs newer than the cached overview's, seen by the graph's check after a page (#373). The graph uses them while the
/// overview still has `staleRefSet`; the overview catches up on its own refresh.
struct GraphLiveRefs: Sendable {
    let staleRefSet: GraphRefSet
    let refs: GraphRefs
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
    /// `refSet` holds every ref the page walked (`GraphRefSet.isComplete`). When it does not, an unchanged `refSet`
    /// does not mean an unchanged history, and `GraphStore` starts over on every refresh (#333).
    var isRefSetComplete = true
}

/// Commit graph pages (#68, ADR-0010 §3). With a commit-graph file each page is its own `--skip`/`-n` read (about
/// 40–50 ms on the bench repository, cached by ref set); without one, pages come from one streamed `log` per ref set
/// (#254), and `--skip` only for pages past where the stream stopped.
extension RepositoryService {
    /// Commits `skip ..< skip + limit` of `log --date-order` over branches, remote-tracking refs, tags, and worktree
    /// HEADs (the refs `GraphRefSet` keys on, #308), with the refs of the cached
    /// overview (loading it first when nothing is cached). Pages are cached by ref set; ⌘R and `forget` drop them.
    /// A ref set that misses refs (`GraphRefSet.isComplete`) is not cached: every page is read again (#333).
    ///
    /// The ref set comes from the cached overview, but `log` reads the refs as they are now. So each fresh read is
    /// checked against the refs read again after it (#373): a page from another history state would otherwise be
    /// joined to the pages before it at the `--skip` boundary. When the refs moved, the graph keeps the newer refs
    /// (`graphLiveRefs`) and reads the page once more under them; the new ref set makes `GraphStore` start over. The
    /// overview itself is left to its own refreshes. If the refs moved again meanwhile, the page is returned like one
    /// with an incomplete ref set: not cached, and `GraphStore` starts over on the next refresh.
    func graphPage(_ repository: Repository, skip: Int, limit: Int) async -> Result<GraphPageSnapshot, GitError> {
        let first = await graphPageRead(repository, skip: skip, limit: limit)
        guard case .moved = first else { return first.result }
        return await graphPageRead(repository, skip: skip, limit: limit).result
    }

    /// One read of a graph page: checked against the refs as they are after it (#373).
    private enum GraphPageRead {
        case checked(Result<GraphPageSnapshot, GitError>)
        /// The page was read from another history state than its ref set's.
        case moved(GraphPageSnapshot)

        var result: Result<GraphPageSnapshot, GitError> {
            switch self {
            case .checked(let result):
                return result
            case .moved(var page):
                page.isRefSetComplete = false  // not cached, and GraphStore starts over on the next refresh
                return .success(page)
            }
        }
    }

    private func graphPageRead(_ repository: Repository, skip: Int, limit: Int) async -> GraphPageRead {
        if cachedOverview(of: repository) == nil {
            guard let refresh = await refresh(repository, trigger: .user) else { return .checked(.failure(.cancelled)) }
            if case .failure(let error) = refresh.result { return .checked(.failure(error)) }
        }
        guard let overview = cachedOverview(of: repository) else { return .checked(.failure(.cancelled)) }
        let id = repository.id
        let listed = GraphRefs(refs: overview.refs, worktrees: overview.entries.map(\.worktree))
        // Newer refs the check saw stand in for the overview's until the overview changes.
        if let live = graphLiveRefs[id], live.staleRefSet != listed.refSet { graphLiveRefs[id] = nil }
        let graphRefs = graphLiveRefs[id]?.refs ?? listed
        let refSet = graphRefs.refSet
        let key = GraphPageKey(repositoryID: id, refSet: refSet, skip: skip, limit: limit)
        let isCacheable =
            graphLiveRefs[id] != nil
            || GraphRefSet.isComplete(refs: overview.refs, isWorktreeListPartial: overview.isWorktreeListPartial)
        func snapshot(_ page: LogParser.GraphPage) -> GraphPageSnapshot {
            GraphPageSnapshot(
                commits: page.commits, isPartial: page.isPartial, refSet: refSet, refs: graphRefs.refs,
                worktrees: graphRefs.worktrees, isRefSetComplete: isCacheable)
        }
        /// After a fresh read: whether `log` saw `refSet`. On a mismatch the graph keeps the refs read now.
        func check() async -> Bool {
            let current = await Self.currentRefs(repository, makeContext(repository))
            guard let current, current.refSet != refSet else { return current != nil }
            graphLiveRefs[id] = GraphLiveRefs(staleRefSet: listed.refSet, refs: current)
            return false
        }
        // Cached pages were checked when they were read.
        if isCacheable, let cached = graphPages.value(for: key) { return .checked(.success(snapshot(cached))) }

        // Without a commit-graph file every `--skip` page re-sorts the whole history: stream it once instead (#254).
        // A stream is kept per ref set, so it is a cache too: a ref set that misses refs cannot see them move, and
        // reads every page with --skip instead (review of #346, #333).
        if isCacheable && !Self.hasCommitGraph(repository) {
            let stream = graphStream(for: repository, refSet: refSet)
            switch await stream.page(skip: skip, limit: limit) {
            case .commits(let commits):
                let page = snapshot(LogParser.GraphPage(commits: commits, isPartial: false))
                // One check per stream: one `log` read one history state.
                guard !stream.isRefSetVerified else { return .checked(.success(page)) }
                guard await check() else {
                    dropGraphStream(stream)
                    return .moved(page)
                }
                stream.markRefSetVerified()
                return .checked(.success(page))
            case .cancelled:
                return .checked(.failure(.cancelled))
            case .beyond:
                break  // the stream stopped before this page: read it with --skip below
            }
        }

        switch await Self.readGraphPage(repository, skip: skip, limit: limit, makeContext(repository)) {
        case .success(let read):
            let page = snapshot(read)
            // An incomplete ref set cannot be checked; GraphStore starts over on every refresh with it (#333).
            guard isCacheable else { return .checked(.success(page)) }
            guard await check() else { return .moved(page) }
            graphPages.insert(read, for: key)
            return .checked(.success(page))
        case .failure(let error):
            return .checked(.failure(error))
        }
    }

    /// Non-isolated: the refs `graphPage` walks now, from the refs and the worktree list read again (#373). Read after
    /// a page, so a match means `log` saw the same refs (a ref that moved and moved back between the two reads is not
    /// seen). `nil` when they cannot be read or are incomplete, which counts as moved.
    private static func currentRefs(_ repository: Repository, _ context: Context) async -> GraphRefs? {
        let directory = repository.rootURL ?? repository.commonGitDirectoryURL
        do {
            let inspection = try await inspect(directory, probe: nil, context)
            guard let safety = inspection.safetyContext else { return nil }
            async let refsRead = context.client.run(.refs, in: directory, safety: safety)
            async let listRead = context.client.run(.worktreeList, in: directory, safety: safety)
            let (refsOutput, listOutput) = try await (refsRead, listRead)
            let refs = try RefParser.parse(refsOutput.stdout, truncated: refsOutput.isTruncated)
            let list = try WorktreeParser.parse(listOutput.stdout, truncated: listOutput.isTruncated)
            guard GraphRefSet.isComplete(refs: refs, isWorktreeListPartial: list.isPartial) else { return nil }
            return GraphRefs(refs: refs, worktrees: uniquePaths(list.worktrees))
        } catch {
            return nil
        }
    }

    /// Repositories that keep a streamed history at once; the oldest is stopped and dropped beyond this. Each keeps up
    /// to 100,000 commits (about 50 MB of models for the bench repository's history; at most the 64 MB stream cap of
    /// strings plus overhead for a hostile one), so two bound it under PB-6 (security review of #254, T15).
    static let maximumGraphStreams = 2

    /// The stream for `refSet`, started if there is none or the history moved (the old one is stopped).
    ///
    /// Streams share one slot (`GitClient`), so another repository's unfinished stream would make this one's first
    /// page wait for it, up to its 120 s timeout. Starting a stream therefore stops other repositories' unfinished
    /// streams: their waiting pages fall back to `--skip`, and they start again when their repository asks. Finished
    /// streams stay (review of #254).
    private func graphStream(for repository: Repository, refSet: GraphRefSet) -> GraphStream {
        let id = repository.id
        if let index = graphStreams.firstIndex(where: { $0.repositoryID == id }) {
            if graphStreams[index].refSet == refSet { return graphStreams[index].stream }
            graphStreams.remove(at: index).stream.cancel()
        }
        for entry in graphStreams where !entry.stream.hasEnded { entry.stream.cancel() }
        graphStreams.removeAll { $0.stream.isCancelled }
        let stream = GraphStream()
        let context = makeContext(repository)
        stream.start { stream in await Self.readGraphStream(repository, into: stream, context) }
        graphStreams.append((id, refSet, stream))
        while graphStreams.count > Self.maximumGraphStreams { graphStreams.removeFirst().stream.cancel() }
        return stream
    }

    /// Stops and forgets `stream` only: a newer stream of the same repository started meanwhile stays.
    private func dropGraphStream(_ stream: GraphStream) {
        graphStreams.removeAll { $0.stream === stream }
        stream.cancel()
    }

    /// Stops and forgets a repository's stream, and the newer refs the graph's check saw (⌘R, `forget`).
    func dropGraphStream(of repositoryID: String) {
        graphLiveRefs[repositoryID] = nil
        while let index = graphStreams.firstIndex(where: { $0.repositoryID == repositoryID }) {
            graphStreams.remove(at: index).stream.cancel()
        }
    }

    /// Whether git can use a commit-graph file here (`objects/info/commit-graph`, or a split chain under
    /// `commit-graphs/`). Only the repository's own object directory counts; alternates are not followed.
    static func hasCommitGraph(_ repository: Repository) -> Bool {
        let info = repository.commonGitDirectoryURL.appendingPathComponent("objects/info", isDirectory: true)
        return FileManager.default.fileExists(atPath: info.appendingPathComponent("commit-graph").path)
            || FileManager.default.fileExists(
                atPath: info.appendingPathComponent("commit-graphs/commit-graph-chain").path)
    }

    /// Non-isolated: streams `graphStream` into `stream` after the same inspection as a page. Returns whether git
    /// finished normally with its whole output.
    private static func readGraphStream(
        _ repository: Repository, into stream: GraphStream, _ context: Context
    ) async -> Bool {
        let directory = repository.rootURL ?? repository.commonGitDirectoryURL
        do {
            let inspection = try await inspect(directory, probe: nil, context)
            guard let safety = inspection.safetyContext else { return false }
            let output = try await context.client.stream(
                .graphStream(limit: stream.maximum), in: directory, safety: safety, onStdout: stream.receive)
            return !output.isTruncated
        } catch {
            return false
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
