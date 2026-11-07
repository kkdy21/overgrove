import Foundation

/// What the ISSUES section has to show (screens.md S-06 states).
enum IssueListContent: Equatable {
    case noGitHubRemote
    case notInstalled
    case notLoggedIn
    /// `detail` is the escaped one-line reason.
    case failed(repository: GitHubRepository, detail: String)
    case loaded(repository: GitHubRepository, issues: [Issue])
}

/// The open repository's issues (S-06, #81), kept apart from `AppState` so gh problems stay in the issue panel
/// (ADR-0004 §4). Loads once per github.com repository and again on ⌘R; a load that finishes after the repository
/// changed is dropped.
@MainActor
@Observable
final class IssuePanelState {
    private let loader: any IssueLoading

    /// `nil` until the repository's remotes are known.
    private(set) var content: IssueListContent? {
        didSet {
            let issues = self.issues
            knownNumbers = Set(issues.map(\.number))
            titles = Dictionary(
                issues.map { ($0.number, PathValidator.displayable($0.title)) }, uniquingKeysWith: { first, _ in first }
            )
        }
    }
    /// The fetched issue numbers and their escaped titles, built once per load for the `#n` badges (#82).
    private(set) var knownNumbers: Set<Int> = []
    private(set) var titles: [Int: String] = [:]
    private(set) var isLoading = false
    /// The github.com repository the issues are read from, shown on S-06 so the user sees where they come from.
    private(set) var repository: GitHubRepository?
    /// The load in flight; tests await it.
    private(set) var task: Task<Void, Never>?
    /// Called with the loaded issues, so a selection of an issue that is gone can fall back.
    var onLoaded: (([Issue]) -> Void)?

    private var isStale = true
    private var generation = 0

    init(loader: any IssueLoading) {
        self.loader = loader
    }

    var issues: [Issue] {
        if case .loaded(_, let issues) = content { return issues }
        return []
    }

    /// The repository's remotes are known (a verified listing). Loads when the repository changed or ⌘R asked;
    /// returns whether it started a load.
    @discardableResult
    func show(_ repository: GitHubRepository?) -> Bool {
        guard let repository else {
            cancel()
            self.repository = nil
            content = .noGitHubRemote
            return false
        }
        guard repository != self.repository || isStale else { return false }
        self.repository = repository
        isStale = false
        load(repository)
        return true
    }

    /// Check Again (#83): reads the same repository's issues again. `false` without one (no GitHub remote): the
    /// caller reloads the repository so its remotes are read again.
    @discardableResult
    func retry() -> Bool {
        guard let repository else { return false }
        isStale = false
        load(repository)
        return true
    }

    /// ⌘R: the next `show` loads again even for the same repository.
    func markStale() {
        isStale = true
    }

    /// Another repository opened, or none.
    func clear() {
        cancel()
        repository = nil
        isStale = true
        content = nil
    }

    private func cancel() {
        task?.cancel()
        task = nil
        generation += 1
        isLoading = false
    }

    private func load(_ repository: GitHubRepository) {
        cancel()
        let generation = generation
        // A different repository's issues are not kept on screen while the new ones load.
        if case .loaded(let shown, _) = content, shown != repository { content = nil }
        isLoading = true
        let loader = loader
        task = Task { [weak self] in
            let result = await loader.issues(in: repository)
            self?.finish(result, repository: repository, generation: generation)
        }
    }

    private func finish(_ result: IssueLoadResult, repository: GitHubRepository, generation: Int) {
        guard generation == self.generation, !Task.isCancelled else { return }
        isLoading = false
        switch result {
        case .issues(let issues):
            content = .loaded(repository: repository, issues: issues)
            onLoaded?(issues)
        case .notInstalled: content = .notInstalled
        case .notLoggedIn: content = .notLoggedIn
        case .failed(let message):
            content = .failed(repository: repository, detail: PathValidator.displayable(message))
        case .cancelled:
            // Try again on the next `show`.
            isStale = true
        }
    }
}
