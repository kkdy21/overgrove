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
}

extension WorktreeListing {
    /// The sidebar's view of a `RepositoryService` load.
    ///
    /// `RepositoryOverview` does not carry `WorktreeParser.Listing.isPartial` yet, so a truncated worktree list is not
    /// reported here (asked of #88).
    init(overview: RepositoryOverview) {
        self.init(
            entries: overview.entries.map { Entry(worktree: $0.worktree, state: Self.state($0.status)) },
            isPartial: false)
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

/// Opens a repository's data: inspect its configuration, then load the worktree list (overview.md §3.2).
protocol RepositoryLoading: Sendable {
    func load(_ repository: Repository) async throws(RepositoryLoadError) -> WorktreeListing
}

/// The app's loader: `configList` → `RepoConfigInspector` → `RepoSafetyContext` → `RepositoryService` (#87), which
/// lists the worktrees and checks and queries each one.
struct LiveRepositoryLoader: RepositoryLoading {
    /// The shared client and service; tests pass ones with a fixture's environment.
    let services: @Sendable () async throws -> (GitClient, RepositoryService)

    static let live = LiveRepositoryLoader(services: { try await LiveGitClient.shared.services() })

    func load(_ repository: Repository) async throws(RepositoryLoadError) -> WorktreeListing {
        do {
            let (client, service) = try await services()
            let directory = repository.rootURL ?? repository.commonGitDirectoryURL
            let config = try await client.run(.configList, in: directory, safety: .preInspection)
            let listing: ConfigParser.Listing
            do {
                listing = try ConfigParser.parse(config.stdout, truncated: config.isTruncated)
            } catch let error as ParseError {
                throw GitError.parseFailed(parser: error.parser, offset: error.offset)
            }
            let inspection = RepoConfigInspector.inspect(listing)
            guard let safety = inspection.safetyContext else {
                throw RepositoryLoadError.blocked(reason: inspection.report.blockingReason ?? "")
            }
            // Opening or selecting a repository is a user request: no debounce (interaction.md).
            guard let refresh = await service.refresh(repository, safety: safety, trigger: .user) else {
                // Superseded by a newer request for the same repository, or cancelled.
                throw GitError.cancelled
            }
            return WorktreeListing(overview: try refresh.result.get())
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
}
