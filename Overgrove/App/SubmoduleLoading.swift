import Foundation

/// Loads the submodules of one worktree for the WIP detail (S-02, #108).
protocol SubmoduleLoading: Sendable {
    /// `nil` when the worktree has no loaded status to go with, or is no longer queried.
    func submodules(_ repository: Repository, worktree: GitPath) async throws(RepositoryLoadError) -> SubmoduleListing?
}

extension LiveRepositoryLoader: SubmoduleLoading {
    func submodules(
        _ repository: Repository, worktree: GitPath
    ) async throws(RepositoryLoadError) -> SubmoduleListing? {
        do {
            let (_, service) = try await services()
            return await service.submodules(of: repository, worktree: worktree)
        } catch let error as GitError {
            throw .git(error)
        } catch {
            throw .git(.launchFailed(errno: -1))
        }
    }
}

/// The selected worktree's submodules and the request behind them (#108). Kept out of `AppState`'s stored properties
/// so its file stays small (#253).
///
/// Reading submodules can start up to `1 + 3 × RepositoryService.maximumInspectedSubmodules` git processes, and every
/// load (auto-refresh included) asks again. So for the same status (SEC-T15-20):
/// - a running read is never cancelled for a refresh; refreshes that arrive meanwhile become one read after it;
/// - a new read starts no sooner than `max(minimumInterval, last read's duration × 10)` after the last one ended,
///   the same pacing as the FSEvents auto-refresh (#119), so submodule reads take at most a tenth of the time.
/// A different status (or worktree) still replaces the request at once.
@MainActor
@Observable
final class SubmodulePanel {
    /// What was asked for one worktree's status, and what came back.
    struct Request: Equatable {
        let path: GitPath
        let state: WorkingState
        var result: Result

        func matches(_ path: GitPath, _ state: WorkingState) -> Bool { self.path == path && self.state == state }
    }

    enum Result: Equatable {
        case pending
        case loaded(SubmoduleListing)
        case failed
    }

    /// The shortest gap between two reads for the same status.
    static let minimumInterval: Duration = .seconds(2)

    private let loader: (any SubmoduleLoading)?
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async throws -> Void
    private(set) var request: Request?
    /// The read in flight, or the wait before it.
    private var task: Task<Void, Never>?
    /// A refresh arrived while `task` was running: read once more after it.
    private var wantsRefresh = false
    /// When the next read for the same status may start.
    private var earliestRead: ContinuousClock.Instant?

    /// - Parameters:
    ///   - now: The clock for pacing; tests pass a manual one.
    ///   - sleep: Waits until the next read may start; tests record it instead.
    init(
        loader: (any SubmoduleLoading)?,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.loader = loader
        self.now = now
        self.sleep = sleep
    }

    /// The listing for `path`'s current status, or `nil` while none is known.
    func result(for path: GitPath, _ state: WorkingState) -> Result? {
        guard let request, request.matches(path, state) else { return nil }
        return request.result
    }

    /// Asks for the submodules of a worktree's status unless the shown one already has them. `refresh` asks again
    /// even for the same status (a load re-queried it; something inside a submodule may have changed), paced as above.
    /// The shown answer stays until the new one arrives.
    func request(_ repository: Repository, path: GitPath, state: WorkingState, refresh: Bool = false) {
        guard let loader else { return }
        let isSame = request?.matches(path, state) ?? false
        if isSame && !refresh { return }
        guard isSame else {
            reset()
            request = Request(path: path, state: state, result: .pending)
            read(loader, repository, path, state, notBefore: nil)
            return
        }
        if task != nil {
            wantsRefresh = true
            return
        }
        read(loader, repository, path, state, notBefore: earliestRead)
    }

    private func read(
        _ loader: any SubmoduleLoading, _ repository: Repository, _ path: GitPath, _ state: WorkingState,
        notBefore: ContinuousClock.Instant?
    ) {
        let now = self.now
        let sleep = self.sleep
        task = Task { [weak self] in
            if let notBefore {
                let wait = notBefore - now()
                if wait > .zero {
                    do { try await sleep(wait) } catch { return }
                }
            }
            guard !Task.isCancelled else { return }
            let began = now()
            var result: Result?
            do throws(RepositoryLoadError) {
                // `nil`: the service has no loaded status for it (e.g. evicted); see `finish`.
                if let listing = try await loader.submodules(repository, worktree: path) { result = .loaded(listing) }
            } catch {
                if error == .git(.cancelled) { return }
                result = .failed
            }
            guard !Task.isCancelled, let self else { return }
            self.finish(result, elapsed: now() - began, loader, repository, path, state)
        }
    }

    private func finish(
        _ result: Result?, elapsed: Duration, _ loader: any SubmoduleLoading, _ repository: Repository,
        _ path: GitPath, _ state: WorkingState
    ) {
        task = nil
        guard request?.matches(path, state) == true else { return }
        if let result {
            request?.result = result
        } else if request?.result == .pending {
            // A first read with nothing to go on (the service no longer has that status, #431): say so rather than
            // "Checking…" forever. A later `nil` keeps what is shown.
            request?.result = .failed
        }
        let earliest = now() + max(Self.minimumInterval, elapsed * 10)
        earliestRead = earliest
        if wantsRefresh {
            wantsRefresh = false
            read(loader, repository, path, state, notBefore: earliest)
        }
    }

    private func reset() {
        task?.cancel()
        task = nil
        wantsRefresh = false
        earliestRead = nil
    }

    func clear() {
        reset()
        request = nil
    }
}
