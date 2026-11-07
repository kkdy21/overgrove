import Foundation

/// The refs a graph page was read with (ADR-0010 §3, overview.md §5): every branch, remote-tracking branch, and tag
/// tip, and every worktree's HEAD (`log --all` follows all of them). Pages continue only within one ref set; when it
/// changes, the graph starts over.
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

/// Commit graph pages (#68, ADR-0010 §3). With a commit-graph file each page is its own `--skip`/`-n` read (about
/// 40–50 ms on the bench repository, cached by ref set); without one, pages come from one streamed `log` per ref set
/// (#254), and `--skip` only for pages past where the stream stopped.
extension RepositoryService {
    /// Commits `skip ..< skip + limit` of `log --all --date-order` (refs/stash excluded), with the refs of the cached
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

        // Without a commit-graph file every `--skip` page re-sorts the whole history: stream it once instead (#254).
        if !Self.hasCommitGraph(repository) {
            switch await graphStream(for: repository, refSet: refSet).page(skip: skip, limit: limit) {
            case .commits(let commits):
                return .success(snapshot(LogParser.GraphPage(commits: commits, isPartial: false)))
            case .cancelled:
                return .failure(.cancelled)
            case .beyond:
                break  // the stream stopped before this page: read it with --skip below
            }
        }

        switch await Self.readGraphPage(repository, skip: skip, limit: limit, makeContext(repository)) {
        case .success(let page):
            graphPages.insert(page, for: key)
            return .success(snapshot(page))
        case .failure(let error):
            return .failure(error)
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

    /// Stops and forgets a repository's stream (⌘R, `forget`).
    func dropGraphStream(of repositoryID: String) {
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
