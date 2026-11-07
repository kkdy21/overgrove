import Foundation

/// What the sidebar's worktree list knows after a load (#65): every listed worktree and the outcome of its status
/// query.
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

/// Loads a repository's worktrees and their status. #87's `RepositoryService` replaces the stand-in below.
protocol WorktreeListProvider: Sendable {
    func worktrees(of repository: Repository, safety: RepoSafetyContext) async throws -> WorktreeListing
}

/// STAND-IN(#87): one worktree at a time, without generations, debounce, or a concurrency limit. #87's
/// `RepositoryService` runs the same steps in parallel and replaces this type.
///
/// Worktree paths come from files the repository controls (`.git/worktrees/<id>/gitdir`), so each one is untrusted:
/// it must report this repository's common directory, and its own configuration is inspected before `status` runs
/// with that worktree's safety context. Both checks use commands allowed before inspection.
struct SequentialWorktreeListProvider: WorktreeListProvider {
    let client: GitClient

    func worktrees(of repository: Repository, safety: RepoSafetyContext) async throws -> WorktreeListing {
        let directory = repository.rootURL ?? repository.commonGitDirectoryURL
        let output = try await client.run(.worktreeList, in: directory, safety: safety)
        let listing = try Self.parsed { try WorktreeParser.parse(output.stdout, truncated: output.isTruncated) }
        let common = PathValidator.canonical(repository.commonGitDirectoryURL)?.path
        var entries: [WorktreeListing.Entry] = []
        for worktree in listing.worktrees {
            try Task.checkCancellation()
            entries.append(
                WorktreeListing.Entry(worktree: worktree, state: try await state(of: worktree, commonDirectory: common))
            )
        }
        return WorktreeListing(entries: entries, isPartial: listing.isPartial)
    }

    private func state(of worktree: Worktree, commonDirectory: String?) async throws -> WorktreeListing.State {
        if worktree.isBare { return .notQueried(.bare) }
        if worktree.isPrunable { return .missing }
        guard let path = worktree.path.argument else { return .notQueried(.unrepresentablePath) }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .missing
        }
        do {
            let probe = try await client.run(.probeRepository, in: directory, safety: .preInspection)
            let reported = try Self.parsed { try ProbeParser.parse(probe.stdout) }.commonDirectory
            guard let commonDirectory, PathValidator.canonical(reported)?.path == commonDirectory else {
                return .notQueried(.foreignRepository)
            }
            let config = try await client.run(.configList, in: directory, safety: .preInspection)
            let inspection = RepoConfigInspector.inspect(
                try Self.parsed { try ConfigParser.parse(config.stdout, truncated: config.isTruncated) })
            guard let safety = inspection.safetyContext else {
                return .notQueried(.inspectionBlocked(inspection.report.blockingReason ?? ""))
            }
            let status = try await client.run(.status, in: directory, safety: safety)
            return .loaded(try Self.parsed { try StatusParser.parse(status.stdout, truncated: status.isTruncated) })
        } catch GitError.worktreeMissing {
            return .missing
        } catch GitError.cancelled {
            throw GitError.cancelled
        } catch let error as GitError {
            return .failed(error)
        }
    }

    /// Parser failures become `GitError.parseFailed` (docs/README.md §2.3).
    private static func parsed<T>(_ parse: () throws -> T) throws -> T {
        do {
            return try parse()
        } catch let error as ParseError {
            throw GitError.parseFailed(parser: error.parser, offset: error.offset)
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

/// The app's loader: `configList` → `RepoConfigInspector` → `RepoSafetyContext` → the worktree list.
struct LiveRepositoryLoader: RepositoryLoading {
    /// Returns the shared client (`LiveGitClient`); tests pass a client with a fixture's environment.
    let client: @Sendable () async throws -> GitClient
    /// STAND-IN(#87): `SequentialWorktreeListProvider` until `RepositoryService` lands.
    let provider: @Sendable (GitClient) -> any WorktreeListProvider

    static let live = LiveRepositoryLoader(
        client: { try await LiveGitClient.shared.client() },
        provider: { SequentialWorktreeListProvider(client: $0) })

    func load(_ repository: Repository) async throws(RepositoryLoadError) -> WorktreeListing {
        do {
            let client = try await client()
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
            return try await provider(client).worktrees(of: repository, safety: safety)
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
