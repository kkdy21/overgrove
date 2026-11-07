import Foundation
import Observation

/// Fetches a repository's remotes for the main window (#77, interaction.md §4.2).
protocol RepositoryFetching: Sendable {
    /// Fetches every remote. `onStart` gets the remote names once they are known.
    func fetch(_ repository: Repository, onStart: @escaping @Sendable ([String]) -> Void) async -> FetchRun
}

/// One failed remote, as the Details sheet shows it (`FetchFailureGuidance`, #78). Every text is app-written except
/// `detail`, which is masked stderr; commands are for the user to copy, never run by Overgrove.
struct FetchFailureDetail: Equatable, Sendable, Identifiable {
    let id: Int
    let summary: String
    let guidance: String
    let commands: [String]
    /// The last lines of masked stderr, escaped for display.
    let detail: String?
}

/// The window's fetch: the status bar field, the Fetch/Stop button, and the record kept per repository (G5).
///
/// One fetch runs at a time per window, and `GitClient` runs one per repository across windows. A fetch that ends
/// (finished or stopped) is recorded and then reported through `onFinished`, so `AppState` re-queries ahead/behind
/// (`.fetchCompleted`).
@MainActor
@Observable
final class FetchController {
    private(set) var status: FetchStatus = .never
    /// The failed remotes of the last fetch, for `Fetch failed — Details`. Empty otherwise.
    private(set) var failures: [FetchFailureDetail] = []
    /// The fetch in flight; tests await it.
    private(set) var task: Task<Void, Never>?
    /// Called on the main actor after a fetch ends, finished or stopped.
    @ObservationIgnored var onFinished: (() -> Void)?

    @ObservationIgnored private let fetcher: (any RepositoryFetching)?
    @ObservationIgnored private let store: FetchRecordStore
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var repository: Repository?
    @ObservationIgnored private var generation = 0

    init(fetcher: (any RepositoryFetching)?, store: FetchRecordStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.fetcher = fetcher
        self.store = store
        self.now = now
    }

    /// Whether Fetch can run: a repository is open and a fetcher exists.
    var canFetch: Bool { fetcher != nil && repository != nil }

    /// Shows `repository`'s last fetch (record, else the `FETCH_HEAD` estimate). A fetch of the previous repository
    /// is stopped and its result dropped.
    func open(_ repository: Repository?) {
        task?.cancel()
        task = nil
        generation += 1
        self.repository = repository
        failures = []
        status = repository.map(store.status(for:)) ?? .never
    }

    /// Starts fetching every remote, unless a fetch already runs (it keeps showing; interaction.md §4.2).
    func fetch() {
        guard let fetcher, let repository, !status.isFetching else { return }
        generation += 1
        let generation = generation
        let lastFetched = status.lastFetched
        failures = []
        status = .fetching(remotes: [], since: now(), lastFetched: lastFetched)
        // Main-actor isolated, so the controller is Sendable; held until this fetch ends (the window stops it when it
        // closes, `MainWindowView`).
        let onStart: @Sendable ([String]) -> Void = { remotes in
            Task { @MainActor in self.started(remotes, generation: generation) }
        }
        task = Task { [weak self] in
            let run = await fetcher.fetch(repository, onStart: onStart)
            self?.finish(run, repository: repository, generation: generation, lastFetched: lastFetched)
        }
    }

    /// Stop / `⌘.`: git is stopped, and the fetch ends as cancelled.
    func stop() {
        task?.cancel()
    }

    #if DEBUG
        /// Shows `status` without fetching (previews and render tests).
        func showForPreview(_ status: FetchStatus, failures: [FetchFailureDetail] = []) {
            self.status = status
            self.failures = failures
        }
    #endif

    /// Forgets the record of a repository removed from Overgrove.
    func forget(_ repositoryID: String) {
        store.remove(repositoryID)
    }

    // MARK: Results

    private func started(_ remotes: [String], generation: Int) {
        guard generation == self.generation, case .fetching(_, let since, let last) = status else { return }
        status = .fetching(remotes: remotes, since: since, lastFetched: last)
    }

    private func finish(_ run: FetchRun, repository: Repository, generation: Int, lastFetched: Date?) {
        guard generation == self.generation else { return }
        task = nil
        switch run {
        case .cancelled:
            status = .cancelled(lastFetched: lastFetched)
        case .finished(let failed):
            let finishedAt = now()
            store.save(
                FetchRecord(
                    repositoryID: repository.id, finishedAt: finishedAt, succeeded: failed.isEmpty,
                    summary: failed.first?.summary))
            if failed.isEmpty {
                status = .idle(lastFetched: finishedAt)
            } else {
                failures = failed.enumerated().map(Self.detail)
                status = .failed(lastFetched: store.entry(for: repository.id)?.lastSucceededAt)
            }
        }
        onFinished?()
    }

    private static func detail(_ index: Int, _ guidance: FetchFailureGuidance) -> FetchFailureDetail {
        FetchFailureDetail(
            id: index,
            summary: PathValidator.displayable(guidance.summary),
            guidance: PathValidator.displayable(guidance.guidance),
            commands: guidance.commands.map(PathValidator.displayable),
            // Line by line: escaping the whole tail would also escape its line breaks.
            detail: guidance.detailTail.map { tail in
                tail.split(separator: "\n").map { PathValidator.displayable(String($0)) }.joined(separator: "\n")
            })
    }
}
