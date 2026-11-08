import Foundation

/// Combines queries for a repository and caches their results (overview.md §3–§5, #87, #88): the worktree list, then
/// every worktree's status, the refs, and the stash list in parallel.
///
/// - **Parallelism** comes from `GitClient`'s query pool (`GitClient.defaultConcurrency`, cores up to 8). The service
///   only starts the queries; the client caps how many git processes run at once.
/// - **Refresh** (`refresh(_:trigger:)`): each request gets the next generation number for its repository. A newer
///   request cancels the one in flight (its git processes are stopped), and a result that is no longer the newest is
///   dropped, so a stale response never reaches the screen.
/// - **Debounce**: automatic requests wait `debounceInterval`, and only the last of a burst runs. Requests the user
///   made (`⌘R`, selecting a worktree) run at once (interaction.md).
/// - **Cache** (overview.md §5): the last result per repository stays in memory (`cachedOverview(of:)`, no git), and
///   each trigger re-queries only what its row of the cache table invalidates. Configuration inspections are cached
///   per worktree until a configuration file changes (`RepoConfigInspectionCache`).
/// - **Untrusted worktree list** (#226): every listed worktree must prove it belongs to the repository before git runs
///   in it, duplicates are listed once, and at most `maximumQueriedWorktrees` are queried.
///
/// The Store owns what is shown; the service keeps the cache and the generation bookkeeping.
actor RepositoryService {
    enum Trigger: Sendable, Equatable {
        /// ⌘R: every cache of the repository is dropped, inspections included. Not debounced.
        case user
        /// Window activation: the worktree list, and statuses last queried `statusFreshness` or more ago. Debounced.
        case automatic
        /// The user selected this worktree: its status only. Not debounced.
        case worktreeSelected(GitPath)
        /// A fetch finished: the worktree list, every status (ahead/behind), and the refs. Debounced.
        case fetchCompleted
        /// Files changed on disk (auto refresh, #119): only these worktrees' statuses, plus the refs or the worktree
        /// list when they changed. Not debounced here; the watcher batches and rate-limits its requests.
        case filesChanged(worktrees: Set<GitPath>, refs: Bool, worktreeList: Bool)

        var isDebounced: Bool {
            switch self {
            case .automatic, .fetchCompleted: true
            case .user, .worktreeSelected, .filesChanged: false
            }
        }
    }

    struct Refresh: Sendable, Equatable {
        let generation: Int
        let result: Result<RepositoryOverview, GitError>
    }

    /// overview.md §4: requests repeated within this interval run once.
    static let debounceInterval: Duration = .milliseconds(300)
    /// overview.md §5: window activation re-queries a status only if it is at least this old.
    static let statusFreshness: Duration = .seconds(5)
    /// Repositories whose results stay cached; the least recently used one is dropped beyond this.
    static let defaultCachedRepositories = 8
    /// Base comparisons kept across all repositories (#157).
    static let cachedComparisons = 32
    /// Commit details kept across all repositories (#69). Commits never change, so only the bound evicts them.
    static let cachedCommitDetails = 200
    /// Graph pages kept across all repositories (#68): 40 pages of 500 commits.
    static let cachedGraphPages = 40
    /// Worktrees queried per load (#226, T15). Each one costs three git processes (probe, config, status), and the list
    /// comes from files the repository controls, so a forged list could otherwise start thousands. PB-1 targets 10.
    static let defaultMaximumQueriedWorktrees = 64
    /// Remotes fetched per Fetch (#259, T15). The list comes from the repository's configuration, and each remote may
    /// take up to 120 seconds one after another, so a list of thousands would never finish. Repositories usually have
    /// one to three remotes (origin, upstream, a few forks); 16 leaves room for fork-heavy review setups while bounding
    /// one Fetch to about 32 minutes in the worst case (and Stop always works).
    static let defaultMaximumFetchedRemotes = 16

    private let client: GitClient
    private let maximumQueriedWorktrees: Int
    /// Remotes one Fetch fetches (#259); read by `fetch(_:onStart:)`.
    let maximumFetchedRemotes: Int
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> ContinuousClock.Instant
    private let inspections = RepoConfigInspectionCache()
    private var cache: BoundedCache<String, CachedRepository>
    private var latestGeneration: [String: Int] = [:]
    private var running: [String: (generation: Int, task: Task<CachedRepository, Error>)] = [:]
    /// WIP line counts per repository and worktree, with the status query time they belong to (#230).
    private var lineCountCache: [String: [GitPath: CachedLineCounts]] = [:]
    /// Base comparisons (#157), keyed so that a moved base tip, a new HEAD, or (with the working tree) a newer status
    /// query makes a new entry (`RepositoryService+Compare.swift`).
    var comparisons = BoundedCache<ComparisonKey, WorktreeComparison>(capacity: RepositoryService.cachedComparisons)
    /// Commit details (#69), by repository and object ID (`RepositoryService+Commit.swift`).
    var commitDetails = BoundedCache<CommitKey, CommitDetail>(capacity: RepositoryService.cachedCommitDetails)
    /// Graph pages (#68), keyed by the ref set they were read with (`RepositoryService+Graph.swift`).
    var graphPages = BoundedCache<GraphPageKey, LogParser.GraphPage>(capacity: RepositoryService.cachedGraphPages)
    /// Streamed histories for repositories without a commit-graph file (#254), newest last; one per repository.
    var graphStreams: [(repositoryID: String, refSet: GraphRefSet, stream: GraphStream)] = []
    /// Refs newer than the cached overview's, seen by the graph's check (#373), by repository.
    var graphLiveRefs: [String: GraphLiveRefs] = [:]

    /// - Parameters:
    ///   - sleep: Waits out the debounce; tests pass a gate instead of real time.
    ///   - now: The clock for status freshness; tests pass a manual one.
    init(
        client: GitClient,
        cachedRepositories: Int = RepositoryService.defaultCachedRepositories,
        maximumQueriedWorktrees: Int = RepositoryService.defaultMaximumQueriedWorktrees,
        maximumFetchedRemotes: Int = RepositoryService.defaultMaximumFetchedRemotes,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.client = client
        self.cache = BoundedCache(capacity: cachedRepositories)
        self.maximumQueriedWorktrees = maximumQueriedWorktrees
        self.maximumFetchedRemotes = max(1, maximumFetchedRemotes)
        self.sleep = sleep
        self.now = now
    }

    // MARK: - Cache

    /// The last delivered result, from memory only (PB-2: paint at once, then refresh).
    func cachedOverview(of repository: Repository) -> RepositoryOverview? {
        cache.value(for: repository.id)?.overview
    }

    /// When the load that last read `repository`'s refs started (#418); `nil` when nothing is cached.
    func cachedRefsTime(of repository: Repository) -> ContinuousClock.Instant? {
        cache.peek(repository.id)?.refsTime
    }

    /// Drops everything about `repository` (removed from the registry). A refresh in flight is cancelled and dropped.
    func forget(_ repository: Repository) async {
        let id = repository.id
        latestGeneration[id] = (latestGeneration[id] ?? 0) + 1
        running[id]?.task.cancel()
        running[id] = nil
        cache.removeValue(for: id)
        lineCountCache[id] = nil
        comparisons.removeAll { $0.repositoryID == id }
        commitDetails.removeAll { $0.repositoryID == id }
        graphPages.removeAll { $0.repositoryID == id }
        dropGraphStream(of: id)
        await inspections.invalidate(keysWithPrefix: Self.inspectionPrefix(repository))
    }

    /// The cached overview, and when `worktree`'s status was last queried, for the comparison cache key (#157).
    func cachedState(
        of repository: Repository, worktree: GitPath
    ) -> (overview: RepositoryOverview, statusQueried: ContinuousClock.Instant?)? {
        guard let cached = cache.value(for: repository.id) else { return nil }
        return (cached.overview, cached.statusTimes[worktree])
    }

    /// The context for loads of `repository`, with the shared inspection cache.
    func makeContext(_ repository: Repository) -> Context {
        Context(
            repository: repository, client: client, inspections: inspections,
            maximumQueriedWorktrees: maximumQueriedWorktrees, now: now())
    }

    // MARK: - Refresh

    /// Refreshes `repository` unless a newer request supersedes this one. Returns `nil` when superseded, debounced
    /// away, or cancelled by the caller; otherwise the result tagged with its generation.
    func refresh(_ repository: Repository, trigger: Trigger) async -> Refresh? {
        let id = repository.id
        // A file-change refresh never replaces a load already running for this repository, from this window or
        // another one (#119): it returns `nil` like a superseded request, and the controller sends it again later.
        if case .filesChanged = trigger, running[id] != nil { return nil }
        let generation = (latestGeneration[id] ?? 0) + 1
        latestGeneration[id] = generation
        running[id]?.task.cancel()  // superseded: stop its git processes now

        if trigger.isDebounced {
            do {
                try await sleep(Self.debounceInterval)
            } catch {
                return nil
            }
        }
        if trigger == .user {
            await inspections.invalidate(keysWithPrefix: Self.inspectionPrefix(repository))
            // ⌘R also re-reads the graph: refs outside the listed namespaces (notes, pull refs) can move unseen.
            graphPages.removeAll { $0.repositoryID == id }
            dropGraphStream(of: id)
        }
        // A newer request arrived while this one waited.
        guard latestGeneration[id] == generation, !Task.isCancelled else { return nil }

        let previous = cache.peek(id)
        let plan = Plan(trigger: trigger, hasCache: previous != nil)
        let context = makeContext(repository)
        let task = Task { try await Self.load(context, previous: previous, plan: plan) }
        running[id] = (generation, task)
        let result: Result<CachedRepository, GitError> = await withTaskCancellationHandler {
            do {
                return .success(try await task.value)
            } catch let error as GitError {
                return .failure(error)
            } catch let error as ParseError {
                return .failure(GitError(error))
            } catch {
                return .failure(.cancelled)
            }
        } onCancel: {
            task.cancel()
        }
        if running[id]?.generation == generation { running[id] = nil }

        guard latestGeneration[id] == generation, !Task.isCancelled else { return nil }
        switch result {
        case .failure(.cancelled):
            return nil
        case .failure:
            cache.removeValue(for: id)  // e.g. the configuration now blocks queries: stop serving the old result
            lineCountCache[id] = nil
        case .success(let loaded):
            cache.insert(loaded, for: id)
            pruneLineCounts()
        }
        return Refresh(generation: generation, result: result.map(\.overview))
    }

    // MARK: - Line counts (#230)

    private struct CachedLineCounts: Sendable {
        let statusTime: ContinuousClock.Instant
        let counts: WorkingLineCounts
    }

    /// Per-file line counts of a listed worktree's uncommitted changes (screens.md S-02), for its WIP detail.
    ///
    /// Runs only for a worktree whose status is cached as loaded, so it follows the same admission as the load (#226).
    /// The result is cached until that worktree's status is queried again (overview.md §5: the same invalidation as
    /// status); until then, asking again runs no git. Returns `nil` when there is no loaded status to go with, or the
    /// worktree is no longer queried.
    func lineCounts(of repository: Repository, worktree path: GitPath) async throws -> WorkingLineCounts? {
        let id = repository.id
        guard let cached = cache.peek(id), let statusTime = cached.statusTimes[path],
            let entry = cached.overview.entries.first(where: { $0.worktree.path == path }),
            case .loaded(let state) = entry.status
        else { return nil }
        if let hit = lineCountCache[id]?[path], hit.statusTime == statusTime { return hit.counts }

        let counts = try await Self.queryLineCounts(of: entry.worktree, state: state, makeContext(repository))
        // Store only if the status is still the one the counts were taken for (a refresh may have run meanwhile).
        if let counts, cache.peek(id)?.statusTimes[path] == statusTime {
            lineCountCache[id, default: [:]][path] = CachedLineCounts(statusTime: statusTime, counts: counts)
        }
        return counts
    }

    /// Keeps only counts whose status is still the cached one, for repositories still cached.
    private func pruneLineCounts() {
        var pruned: [String: [GitPath: CachedLineCounts]] = [:]
        for (id, perWorktree) in lineCountCache {
            guard let times = cache.peek(id)?.statusTimes else { continue }
            let kept = perWorktree.filter { path, value in times[path] == value.statusTime }
            if !kept.isEmpty { pruned[id] = kept }
        }
        lineCountCache = pruned
    }

    // MARK: - Loading

    /// One full load without the result cache or refresh coordination (overview.md §3.2 steps 3–5, PB-1).
    func loadOverview(of repository: Repository) async throws -> RepositoryOverview {
        let context = Context(
            repository: repository, client: client, inspections: nil, maximumQueriedWorktrees: maximumQueriedWorktrees,
            now: now())
        return try await Self.load(context, previous: nil, plan: Plan(trigger: .user, hasCache: false)).overview
    }

    private struct CachedRepository: Sendable {
        let overview: RepositoryOverview
        /// When each listed worktree's status was last queried.
        let statusTimes: [GitPath: ContinuousClock.Instant]
        /// When the load that last read the refs started (#418): the graph's kept refs give way to refs read later.
        var refsTime: ContinuousClock.Instant?
    }

    struct Context: Sendable {
        let repository: Repository
        let client: GitClient
        /// `nil` for an uncached load.
        let inspections: RepoConfigInspectionCache?
        let maximumQueriedWorktrees: Int
        let now: ContinuousClock.Instant
    }

    /// What one refresh queries, from the cache table (overview.md §5). Refs and the stash list are also re-queried
    /// when fresh statuses show they changed (`load`).
    private struct Plan: Sendable {
        enum Statuses: Sendable {
            case all
            case only(GitPath)
            case some(Set<GitPath>)
            case olderThan(Duration)
        }

        let worktreeList: Bool
        let statuses: Statuses
        let refs: Bool
        let stashes: Bool

        init(trigger: Trigger, hasCache: Bool) {
            switch (trigger, hasCache) {
            case (.user, _), (_, false):
                (worktreeList, statuses, refs, stashes) = (true, .all, true, true)
            case (.fetchCompleted, true):
                (worktreeList, statuses, refs, stashes) = (true, .all, true, false)
            case (.automatic, true):
                (worktreeList, statuses, refs, stashes) = (
                    true, .olderThan(RepositoryService.statusFreshness), false, false
                )
            case (.worktreeSelected(let path), true):
                (worktreeList, statuses, refs, stashes) = (false, .only(path), false, false)
            case (.filesChanged(let worktrees, let changedRefs, let changedList), true):
                (worktreeList, statuses, refs, stashes) = (changedList, .some(worktrees), changedRefs, false)
            }
        }
    }

    private enum Part: Sendable {
        case status(RepositoryOverview.Entry)
        case refs(RefParser.Listing)
        case stashes(StashParser.Listing)
    }

    /// Non-isolated, so the parallel queries do not queue on this actor.
    private static func load(
        _ context: Context,
        previous: CachedRepository?,
        plan: Plan
    ) async throws -> CachedRepository {
        let repository = context.repository
        let directory = repository.rootURL ?? repository.commonGitDirectoryURL
        let inspection = try await inspect(directory, probe: nil, context)
        guard let safety = inspection.safetyContext else {
            throw GitError.configInspectionFailed(reason: inspection.report.blockingReason ?? "")
        }

        let (listed, isListPartial) = try await worktreeList(context, safety: safety, previous: previous, plan: plan)
        let worktrees = uniquePaths(listed)
        let admissions = admit(worktrees, limit: context.maximumQueriedWorktrees)
        let stale: [(Worktree, URL)] = zip(worktrees, admissions).compactMap { worktree, admission in
            guard case .query(let folder) = admission, needsStatus(worktree, plan, previous, at: context.now) else {
                return nil
            }
            return (worktree, folder)
        }

        var fresh: [GitPath: RepositoryOverview.Entry] = [:]
        var refs: RefParser.Listing?
        var stashes: StashParser.Listing?
        try await withThrowingTaskGroup(of: Part.self) { group in
            for (worktree, folder) in stale {
                group.addTask { .status(await Self.status(of: worktree, at: folder, context)) }
            }
            if plan.refs || previous == nil {
                group.addTask { .refs(try await Self.refs(context, directory: directory, safety: safety)) }
            }
            if plan.stashes || previous == nil {
                group.addTask { .stashes(try await Self.stashes(context, directory: directory, safety: safety)) }
            }
            for try await part in group {
                switch part {
                case .status(let entry): fresh[entry.worktree.path] = entry
                case .refs(let listing): refs = listing
                case .stashes(let listing): stashes = listing
                }
            }
        }

        // Derived invalidation: fresh statuses show a moved branch tip or a different stash count.
        let states = fresh.values.compactMap { if case .loaded(let state) = $0.status { state } else { nil } }
        let cachedRefs = refs == nil ? previous?.overview.refs : nil
        let cachedStashes = stashes == nil ? previous?.overview.stashes : nil
        let refsMoved = cachedRefs.map { !tipsMatch($0, states, worktrees) } ?? false
        let stashesChanged = cachedStashes.map { !countMatches($0, states) } ?? false
        async let checkedRefs = refreshedIfNeeded(cachedRefs, needed: refsMoved) {
            try await Self.refs(context, directory: directory, safety: safety)
        }
        async let checkedStashes = refreshedIfNeeded(cachedStashes, needed: stashesChanged) {
            try await Self.stashes(context, directory: directory, safety: safety)
        }
        let (rechecked, recounted) = try await (checkedRefs, checkedStashes)
        let finalRefs = refs ?? rechecked
        let readRefs = refs != nil || refsMoved
        let finalStashes = stashes ?? recounted

        // A cancelled refresh ends here, instead of reporting every worktree as failed.
        guard !Task.isCancelled, let finalRefs, let finalStashes else { throw GitError.cancelled }
        var loaded = assemble(
            zip(worktrees, admissions).map { ($0, $1) }, isListPartial: isListPartial, fresh: fresh,
            previous: previous, at: context.now,
            refs: finalRefs, stashes: finalStashes, inspection: inspection)
        loaded.refsTime = readRefs ? context.now : previous?.refsTime
        return loaded
    }

    private static func worktreeList(
        _ context: Context,
        safety: RepoSafetyContext,
        previous: CachedRepository?,
        plan: Plan
    ) async throws -> ([Worktree], Bool) {
        if let previous, !plan.worktreeList {
            let worktrees = previous.overview.entries.map(\.worktree)
            // A selection the cached list does not know needs the current list.
            let isKnown: Bool
            switch plan.statuses {
            case .only(let path):
                isKnown = worktrees.contains { $0.path == path }
            case .some(let paths):
                let listed = Set(worktrees.map(\.path))
                isKnown = paths.allSatisfy(listed.contains)
            case .all, .olderThan:
                isKnown = true
            }
            if isKnown { return (worktrees, previous.overview.isWorktreeListPartial) }
        }
        let directory = context.repository.rootURL ?? context.repository.commonGitDirectoryURL
        let output = try await context.client.run(.worktreeList, in: directory, safety: safety)
        let listing = try WorktreeParser.parse(output.stdout, truncated: output.isTruncated)
        return (listing.worktrees, listing.isPartial)
    }

    private static func needsStatus(
        _ worktree: Worktree,
        _ plan: Plan,
        _ previous: CachedRepository?,
        at now: ContinuousClock.Instant
    ) -> Bool {
        guard let queried = previous?.statusTimes[worktree.path] else { return true }
        switch plan.statuses {
        case .all: return true
        case .only(let path): return worktree.path == path
        case .some(let paths): return paths.contains(worktree.path)
        case .olderThan(let age): return now - queried >= age
        }
    }

    private static func refreshedIfNeeded<Value: Sendable>(
        _ cached: Value?,
        needed: Bool,
        _ query: @Sendable () async throws -> Value
    ) async throws -> Value? {
        guard let cached else { return nil }
        return needed ? try await query() : cached
    }

    /// Every fresh branch tip (status and worktree list) matches the cached refs.
    private static func tipsMatch(_ refs: RefParser.Listing, _ states: [WorkingState], _ worktrees: [Worktree]) -> Bool
    {
        var tips: [String: ObjectID] = [:]
        for branch in refs.branches where branch.kind == .local { tips[branch.fullName] = branch.target }
        for state in states {
            guard case .branch(let name) = state.head, let commit = state.headCommit else { continue }
            if tips["refs/heads/\(name)"] != commit { return false }
        }
        for worktree in worktrees {
            guard let branch = worktree.branch, let head = worktree.head else { continue }
            if tips[branch] != head { return false }
        }
        return true
    }

    /// Every fresh status reports the cached number of stashes (`# stash N`, overview.md §5).
    private static func countMatches(_ stashes: StashParser.Listing, _ states: [WorkingState]) -> Bool {
        !stashes.isPartial && states.allSatisfy { $0.stashCount == stashes.stashes.count }
    }

    private static func assemble(
        _ worktrees: [(Worktree, Admission)],
        isListPartial: Bool,
        fresh: [GitPath: RepositoryOverview.Entry],
        previous: CachedRepository?,
        at now: ContinuousClock.Instant,
        refs: RefParser.Listing,
        stashes: StashParser.Listing,
        inspection: RepoConfigInspection
    ) -> CachedRepository {
        let cached = Dictionary(
            (previous?.overview.entries ?? []).map { ($0.worktree.path, $0) }, uniquingKeysWith: { $1 })
        var times: [GitPath: ContinuousClock.Instant] = [:]
        let entries = worktrees.map { worktree, admission in
            let path = worktree.path
            if case .skip(let status) = admission {
                return RepositoryOverview.Entry(worktree: worktree, status: status)
            }
            if let entry = fresh[path] {
                times[path] = now
                return RepositoryOverview.Entry(
                    worktree: worktree, status: entry.status, inspection: entry.inspection,
                    statusDuration: entry.statusDuration)
            }
            times[path] = previous?.statusTimes[path]
            // The listed worktree is the current one; its status and inspection come from the last query.
            let last = cached[path]
            return RepositoryOverview.Entry(
                worktree: worktree, status: last?.status ?? .failed(.cancelled), inspection: last?.inspection,
                statusDuration: last?.statusDuration)
        }
        let overview = RepositoryOverview(
            entries: entries, isWorktreeListPartial: isListPartial, refs: refs, stashes: stashes,
            inspection: inspection)
        return CachedRepository(overview: overview, statusTimes: times)
    }

    private static func refs(
        _ context: Context, directory: URL, safety: RepoSafetyContext
    ) async throws -> RefParser.Listing {
        let output = try await context.client.run(.refs, in: directory, safety: safety)
        return try RefParser.parse(output.stdout, truncated: output.isTruncated)
    }

    private static func stashes(
        _ context: Context, directory: URL, safety: RepoSafetyContext
    ) async throws -> StashParser.Listing {
        let output = try await context.client.run(.stashList, in: directory, safety: safety)
        return try StashParser.parse(output.stdout, truncated: output.isTruncated)
    }

    private enum Admission: Sendable {
        /// Query the worktree in this folder: its path resolved once, so every command sees the same folder.
        case query(URL)
        case skip(RepositoryOverview.Status)
    }

    private static func skipReason(_ worktree: Worktree) -> RepositoryOverview.Reason? {
        if worktree.isPrunable { return .prunable }
        if worktree.isBare { return .bare }
        if !worktree.path.isRepresentable { return .unrepresentablePath }
        return nil
    }

    /// The list without repeated paths: forged records can repeat one, and a path is the entry's identity (#226).
    static func uniquePaths(_ worktrees: [Worktree]) -> [Worktree] {
        var seen: Set<GitPath> = []
        return worktrees.filter { seen.insert($0.path).inserted }
    }

    /// Which worktrees may be queried (#226): each folder once (after `realpath(3)`), and at most `limit` of them.
    private static func admit(_ worktrees: [Worktree], limit: Int) -> [Admission] {
        var folders: Set<String> = []
        return worktrees.map { worktree in
            if let reason = skipReason(worktree) { return .skip(.notQueried(reason)) }
            let listed = URL(fileURLWithPath: worktree.path.display, isDirectory: true)
            guard let folder = PathValidator.canonical(listed) else {
                return .skip(.failed(.worktreeMissing(path: listed.path)))
            }
            guard !folders.contains(folder.path) else { return .skip(.notQueried(.duplicate)) }
            guard folders.count < limit else { return .skip(.notQueried(.limit)) }
            folders.insert(folder.path)
            return .query(folder)
        }
    }
}
