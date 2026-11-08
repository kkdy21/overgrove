import Foundation

enum PullRequestLoadResult: Sendable, Equatable {
    case pullRequests([PullRequest])
    /// gh is missing, logged out, timed out, or printed something else: PR status is hidden (ADR-0023 §6–§7).
    case unavailable
    case cancelled
}

protocol PullRequestLoading: Sendable {
    func pullRequests(in repository: GitHubRepository) async -> PullRequestLoadResult
}

struct LivePullRequestLoader: PullRequestLoading {
    let client: GHClient

    static let live = LivePullRequestLoader(client: GHClient())

    func pullRequests(in repository: GitHubRepository) async -> PullRequestLoadResult {
        do {
            return .pullRequests(try await client.pullRequests(in: repository))
        } catch GHError.cancelled {
            return .cancelled
        } catch is GHError {
            return .unavailable
        } catch {
            return .cancelled
        }
    }
}

/// The open repository's pull requests and which local branch each belongs to (ADR-0023, #115).
///
/// Loaded alongside the issue list, for the same github.com repository and at the same times (⌘R, Check Again, a new
/// repository). Any failure only hides PR status: the issue panel and Git features never depend on it (§6). A load
/// that finishes after the repository changed is dropped.
@MainActor
@Observable
final class PullRequestStore {
    private let loader: any PullRequestLoading

    /// The listed pull requests; empty when unavailable.
    private(set) var pullRequests: [PullRequest] = [] {
        didSet { rebuildLinks() }
    }
    private(set) var links: PullRequestLinkIndex = .empty
    /// The repository the pull requests were read from; PR URLs are opened only when they point into it.
    private(set) var repository: GitHubRepository?
    /// The load in flight; tests await it.
    private(set) var task: Task<Void, Never>?

    @ObservationIgnored private var branches: [Branch] = []
    @ObservationIgnored private var remotes: [String: GitHubRepository] = [:]
    @ObservationIgnored private var generation = 0

    init(loader: any PullRequestLoading) {
        self.loader = loader
    }

    /// A verified listing's local branches and github.com remotes.
    func update(branches: [Branch], remotes: [String: GitHubRepository]) {
        self.branches = branches
        self.remotes = remotes
        rebuildLinks()
    }

    /// Reads `repository`'s pull requests again, or hides them without one.
    func load(_ repository: GitHubRepository?) {
        cancel()
        if repository != self.repository { pullRequests = [] }
        self.repository = repository
        guard let repository else { return }
        let generation = generation
        let loader = loader
        task = Task { [weak self] in
            let result = await loader.pullRequests(in: repository)
            self?.finish(result, repository: repository, generation: generation)
        }
    }

    /// Another repository opened, or none.
    func clear() {
        cancel()
        repository = nil
        branches = []
        remotes = [:]
        pullRequests = []
    }

    private func cancel() {
        task?.cancel()
        task = nil
        generation += 1
    }

    private func finish(_ result: PullRequestLoadResult, repository: GitHubRepository, generation: Int) {
        guard generation == self.generation, !Task.isCancelled, repository == self.repository else { return }
        switch result {
        case .pullRequests(let pullRequests): self.pullRequests = pullRequests
        case .unavailable: pullRequests = []
        case .cancelled: break
        }
    }

    private func rebuildLinks() {
        let links = PullRequestLinkIndex(pullRequests: pullRequests, branches: branches, remotes: remotes)
        if links != self.links { self.links = links }
    }
}
