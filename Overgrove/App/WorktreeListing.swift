import Foundation

/// What the sidebar's worktree list knows after a load (#65): every listed worktree and the outcome of its status
/// query. Built from `RepositoryOverview` (#87).
struct WorktreeListing: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case loaded(WorkingState)
        /// The folder is gone: listed as prunable, or deleted since (`GitError.worktreeMissing`). Never queried.
        case missing
        /// This worktree's status failed; the other worktrees are unaffected.
        case failed(GitError)
        case notQueried(NotQueriedReason)
    }

    enum NotQueriedReason: Sendable, Equatable {
        /// A bare main repository has no working tree.
        case bare
        /// The path is not valid UTF-8, so it cannot be passed to git (parsing-spec.md §1.3).
        case unrepresentablePath
        /// The listed path belongs to another repository (forged `.git/worktrees/<id>/gitdir`, T14).
        case foreignRepository
        /// The worktree's own configuration (`config.worktree`) blocks queries (ADR-0009, fail closed).
        case inspectionBlocked(String)
        /// Another entry leads to the same folder, which is queried once (#226).
        case duplicate
        /// More worktrees are listed than one load queries (#226, T15).
        case limit
    }

    struct Entry: Sendable, Equatable {
        let worktree: Worktree
        let state: State
    }

    /// In `worktree list` order: the main worktree first.
    let entries: [Entry]
    /// `worktree list` was cut at the size limit and its last record dropped (parsing-spec.md §1.5).
    let isPartial: Bool

    /// Some listed worktrees were not queried because of the per-load limit (#226); the sidebar says so (#243).
    var isQueryLimited: Bool {
        entries.contains { $0.state == .notQueried(.limit) }
    }
}

extension WorktreeListing {
    /// The sidebar's view of a `RepositoryService` load.
    init(overview: RepositoryOverview) {
        self.init(
            entries: overview.entries.map { Entry(worktree: $0.worktree, state: Self.state($0.status)) },
            isPartial: overview.isWorktreeListPartial)
    }

    private static func state(_ status: RepositoryOverview.Status) -> State {
        switch status {
        case .loaded(let state): .loaded(state)
        // The folder vanished between the list and the status query.
        case .failed(.worktreeMissing): .missing
        case .failed(let error): .failed(error)
        case .notQueried(.prunable): .missing
        case .notQueried(.bare): .notQueried(.bare)
        case .notQueried(.unrepresentablePath): .notQueried(.unrepresentablePath)
        case .notQueried(.foreignRepository): .notQueried(.foreignRepository)
        case .notQueried(.inspectionBlocked(let reason)): .notQueried(.inspectionBlocked(reason))
        case .notQueried(.duplicate): .notQueried(.duplicate)
        case .notQueried(.limit): .notQueried(.limit)
        }
    }
}

/// Why a repository could not be loaded at all.
enum RepositoryLoadError: Error, Equatable, Sendable {
    /// `RepoConfigInspector` found configuration it cannot neutralize (ADR-0009, fail closed).
    case blocked(reason: String)
    case git(GitError)

    var message: String {
        switch self {
        case .blocked(let reason):
            "Overgrove stopped querying this repository for safety. \(reason)"
        case .git(let error):
            error.message
        }
    }
}

/// Opens a repository's data: inspect its configuration, then load the worktree list (overview.md §3.2), with the
/// result cache and refresh triggers of `RepositoryService` (overview.md §4–§5, #88, #243).
protocol RepositoryLoading: Sendable {
    /// A full load (`.user`). Superseded or cancelled loads throw `.git(.cancelled)`.
    func load(_ repository: Repository) async throws(RepositoryLoadError) -> WorktreeListing
    /// A refresh for `trigger`. `nil` when a newer request superseded it or it was debounced away; the caller keeps
    /// what it shows.
    func load(
        _ repository: Repository, trigger: RepositoryService.Trigger
    ) async throws(RepositoryLoadError) -> WorktreeListing?
    /// The last delivered listing, from memory only (no git), for painting before a refresh (PB-2).
    func cachedListing(_ repository: Repository) async -> WorktreeListing?
    /// Drops everything cached about `repository` (removed from Overgrove).
    func forget(_ repository: Repository) async
}

extension RepositoryLoading {
    /// A loader without a cache can only load everything: `.user` is a full load, and the narrower triggers have
    /// nothing to refresh (`nil`, keep what is shown).
    func load(
        _ repository: Repository, trigger: RepositoryService.Trigger
    ) async throws(RepositoryLoadError) -> WorktreeListing? {
        guard trigger == .user else { return nil }
        return try await load(repository)
    }

    func cachedListing(_ repository: Repository) async -> WorktreeListing? { nil }

    func forget(_ repository: Repository) async {}
}

/// The app's loader: `RepositoryService` (#87, #88) inspects the repository's configuration (cached until a
/// configuration file changes), lists the worktrees, and checks and queries each one.
struct LiveRepositoryLoader: RepositoryLoading {
    /// The shared client and service; tests pass ones with a fixture's environment.
    let services: @Sendable () async throws -> (GitClient, RepositoryService)

    static let live = LiveRepositoryLoader(services: { try await LiveGitClient.shared.services() })

    func load(_ repository: Repository) async throws(RepositoryLoadError) -> WorktreeListing {
        // Opening a repository and ⌘R are user requests: no debounce (interaction.md).
        guard let listing = try await load(repository, trigger: .user) else {
            // Superseded by a newer request for the same repository, or cancelled.
            throw .git(.cancelled)
        }
        return listing
    }

    func load(
        _ repository: Repository, trigger: RepositoryService.Trigger
    ) async throws(RepositoryLoadError) -> WorktreeListing? {
        do {
            let (_, service) = try await services()
            guard let refresh = await service.refresh(repository, trigger: trigger) else { return nil }
            switch refresh.result {
            case .success(let overview):
                return WorktreeListing(overview: overview)
            case .failure(.configInspectionFailed(let reason)):
                throw RepositoryLoadError.blocked(reason: reason)
            case .failure(let error):
                throw error
            }
        } catch let error as RepositoryLoadError {
            throw error
        } catch let error as GitError {
            throw .git(error)
        } catch is CancellationError {
            throw .git(.cancelled)
        } catch {
            throw .git(.launchFailed(errno: -1))
        }
    }

    func cachedListing(_ repository: Repository) async -> WorktreeListing? {
        // Without a git executable there is no service and so no cache.
        guard let (_, service) = try? await services() else { return nil }
        return await service.cachedOverview(of: repository).map(WorktreeListing.init(overview:))
    }

    func forget(_ repository: Repository) async {
        guard let (_, service) = try? await services() else { return }
        await service.forget(repository)
    }
}
