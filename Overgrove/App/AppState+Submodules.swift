import Foundation

/// S-02's Submodules section (#108): only the selected worktree's submodules, asked for with its line counts.
extension AppState {
    /// The section for the selected worktree's current status, `nil` when there is nothing to show.
    var submoduleSection: SubmoduleSectionModel? {
        guard case .wip(let path) = selection, case .loaded(let listing) = worktreeList,
            let entry = listing.entries.first(where: { $0.worktree.path == path }),
            case .loaded(let state) = entry.state
        else { return nil }
        return SubmoduleSectionModel(submodules.result(for: path, state))
    }

    /// Asks for the selected worktree's submodules once its status has loaded (`requestLineCounts` calls this).
    func requestSubmodules(refresh: Bool = false) {
        guard let repository, case .wip(let path) = selection, case .loaded(let listing) = worktreeList,
            let entry = listing.entries.first(where: { $0.worktree.path == path }),
            case .loaded(let state) = entry.state
        else { return }
        submodules.request(repository.repository, path: path, state: state, refresh: refresh)
    }
}
