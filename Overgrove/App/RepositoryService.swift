import Foundation

/// Combines queries for a repository (overview.md §3–§4, #87): the worktree list, then every worktree's status, the
/// refs, and the stash list in parallel.
///
/// - **Parallelism** comes from `GitClient`'s query pool (`GitClient.defaultConcurrency`, cores up to 8). The service
///   only starts the queries; the client caps how many git processes run at once.
/// - **Refresh** (`refresh(_:safety:trigger:)`): each request gets the next generation number for its repository. A
///   newer request cancels the one in flight (its git processes are stopped), and a result that is no longer the
///   newest is dropped, so a stale response never reaches the screen.
/// - **Debounce**: automatic requests wait `debounceInterval`, and only the last of a burst runs. A refresh the user
///   asked for (`⌘R`) runs at once (interaction.md).
///
/// It keeps no repository state beyond the generation bookkeeping; the Store owns what is shown.
actor RepositoryService {
    enum Trigger: Sendable {
        /// The user asked (⌘R, selecting the repository): no debounce.
        case user
        /// Window activation, file system events, fetch completion: debounced.
        case automatic
    }

    struct Refresh: Sendable, Equatable {
        let generation: Int
        let result: Result<RepositoryOverview, GitError>
    }

    /// overview.md §4: requests repeated within this interval run once.
    static let debounceInterval: Duration = .milliseconds(300)

    private let client: GitClient
    private let sleep: @Sendable (Duration) async throws -> Void
    private var latestGeneration: [String: Int] = [:]
    private var running: [String: (generation: Int, task: Task<RepositoryOverview, Error>)] = [:]

    /// - Parameter sleep: Waits out the debounce; tests pass a gate instead of real time.
    init(
        client: GitClient,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.sleep = sleep
    }

    // MARK: - Refresh

    /// Loads `repository` unless a newer request supersedes this one. Returns `nil` when superseded, debounced away,
    /// or cancelled by the caller; otherwise the result tagged with its generation.
    func refresh(_ repository: Repository, safety: RepoSafetyContext, trigger: Trigger) async -> Refresh? {
        let id = repository.id
        let generation = (latestGeneration[id] ?? 0) + 1
        latestGeneration[id] = generation
        running[id]?.task.cancel()  // superseded: stop its git processes now

        if trigger == .automatic {
            do {
                try await sleep(Self.debounceInterval)
            } catch {
                return nil
            }
            // A newer request arrived while this one waited.
            guard latestGeneration[id] == generation else { return nil }
        }
        guard !Task.isCancelled else { return nil }

        let task = Task { [client] in try await Self.loadOverview(of: repository, safety: safety, client: client) }
        running[id] = (generation, task)
        let result: Result<RepositoryOverview, GitError> = await withTaskCancellationHandler {
            do {
                return .success(try await task.value)
            } catch let error as GitError {
                return .failure(error)
            } catch {
                return .failure(.cancelled)
            }
        } onCancel: {
            task.cancel()
        }
        if running[id]?.generation == generation { running[id] = nil }

        guard latestGeneration[id] == generation, !Task.isCancelled, result != .failure(.cancelled) else { return nil }
        return Refresh(generation: generation, result: result)
    }

    // MARK: - Loading

    /// One load without refresh coordination (overview.md §3.2 steps 4–5).
    func loadOverview(of repository: Repository, safety: RepoSafetyContext) async throws -> RepositoryOverview {
        try await Self.loadOverview(of: repository, safety: safety, client: client)
    }

    /// Non-isolated, so the parallel queries do not queue on this actor.
    private static func loadOverview(
        of repository: Repository,
        safety: RepoSafetyContext,
        client: GitClient
    ) async throws -> RepositoryOverview {
        let directory = repository.rootURL ?? repository.commonGitDirectoryURL
        let list = try await client.run(.worktreeList, in: directory, safety: safety)
        let listing = try WorktreeParser.parse(list.stdout, truncated: list.isTruncated)

        return try await withThrowingTaskGroup(of: Part.self) { group in
            for (index, worktree) in listing.worktrees.enumerated() where Self.skipReason(worktree) == nil {
                group.addTask {
                    .status(index, await Self.status(of: worktree, in: repository, client: client))
                }
            }
            group.addTask {
                let output = try await client.run(.refs, in: directory, safety: safety)
                return .refs(try RefParser.parse(output.stdout, truncated: output.isTruncated))
            }
            group.addTask {
                let output = try await client.run(.stashList, in: directory, safety: safety)
                return .stashes(try StashParser.parse(output.stdout, truncated: output.isTruncated))
            }

            var statuses: [Int: RepositoryOverview.Status] = [:]
            var refs: RefParser.Listing?
            var stashes: StashParser.Listing?
            for try await part in group {
                switch part {
                case .status(let index, let status): statuses[index] = status
                case .refs(let listing): refs = listing
                case .stashes(let listing): stashes = listing
                }
            }
            let entries = listing.worktrees.enumerated().map { index, worktree in
                RepositoryOverview.Entry(
                    worktree: worktree,
                    status: Self.skipReason(worktree).map { .notQueried($0) } ?? statuses[index] ?? .failed(.cancelled)
                )
            }
            // A cancelled refresh ends here, instead of reporting every worktree as failed.
            guard !Task.isCancelled, let refs, let stashes else { throw GitError.cancelled }
            return RepositoryOverview(entries: entries, refs: refs, stashes: stashes)
        }
    }

    /// Compared after `realpath(3)` (PathValidator), so a symbolic link cannot make two folders look alike or apart.
    private static func isSameDirectory(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhs = PathValidator.canonical(lhs), let rhs = PathValidator.canonical(rhs) else { return false }
        return lhs.path == rhs.path
    }

    private enum Part: Sendable {
        case status(Int, RepositoryOverview.Status)
        case refs(RefParser.Listing)
        case stashes(StashParser.Listing)
    }

    private static func skipReason(_ worktree: Worktree) -> RepositoryOverview.Reason? {
        if worktree.isPrunable { return .prunable }
        if worktree.isBare { return .bare }
        if !worktree.path.isRepresentable { return .unrepresentablePath }
        return nil
    }

    /// One worktree's status. Errors stay with that worktree, except cancellation, which ends the whole load.
    ///
    /// Worktree paths come from files the repository controls (`.git/worktrees/<id>/gitdir`), so each one is treated
    /// as untrusted (security review of #221): it must belong to this repository (same git common directory), and its
    /// own configuration is inspected (a linked worktree can have `config.worktree`) before `status` runs with that
    /// worktree's safety context. Both checks use the commands allowed before inspection.
    private static func status(
        of worktree: Worktree,
        in repository: Repository,
        client: GitClient
    ) async -> RepositoryOverview.Status {
        let directory = URL(fileURLWithPath: worktree.path.display, isDirectory: true)
        do {
            let output = try await client.run(.probeRepository, in: directory, safety: .preInspection)
            guard let probe = try? ProbeParser.parse(output.stdout),
                isSameDirectory(probe.commonDirectory, repository.commonGitDirectoryURL)
            else { return .notQueried(.foreignRepository) }

            let config = try await client.run(.configList, in: directory, safety: .preInspection)
            let inspection = RepoConfigInspector.inspect(
                try ConfigParser.parse(config.stdout, truncated: config.isTruncated))
            guard let safety = inspection.safetyContext else {
                return .notQueried(.inspectionBlocked(inspection.report.blockingReason ?? ""))
            }

            let status = try await client.run(.status, in: directory, safety: safety)
            return .loaded(try StatusParser.parse(status.stdout, truncated: status.isTruncated))
        } catch let error as GitError {
            return .failed(error)
        } catch let error as ParseError {
            return .failed(GitError(error))
        } catch {
            return .failed(.cancelled)
        }
    }
}
