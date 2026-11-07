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

    private let loader: (any SubmoduleLoading)?
    private(set) var request: Request?
    private var task: Task<Void, Never>?

    init(loader: (any SubmoduleLoading)?) {
        self.loader = loader
    }

    /// The listing for `path`'s current status, or `nil` while none is known.
    func result(for path: GitPath, _ state: WorkingState) -> Result? {
        guard let request, request.matches(path, state) else { return nil }
        return request.result
    }

    /// Asks for the submodules of a worktree's status unless the shown one already has them. `refresh` asks again
    /// even for the same status (a load re-queried it; something inside a submodule may have changed).
    func request(_ repository: Repository, path: GitPath, state: WorkingState, refresh: Bool = false) {
        guard let loader else { return }
        let isSame = request?.matches(path, state) ?? false
        if isSame && !refresh { return }
        task?.cancel()
        if !isSame { request = Request(path: path, state: state, result: .pending) }
        task = Task { [weak self] in
            let result: Result
            do throws(RepositoryLoadError) {
                guard let listing = try await loader.submodules(repository, worktree: path) else { return }
                result = .loaded(listing)
            } catch {
                if error == .git(.cancelled) { return }
                result = .failed
            }
            guard !Task.isCancelled, let self, self.request?.matches(path, state) == true else { return }
            self.request?.result = result
        }
    }

    func clear() {
        task?.cancel()
        task = nil
        request = nil
    }
}
