import Foundation
import Observation

/// The setup assistant (S-07, #85): shown on first run when no repository is registered, and again from Help ›
/// Setup Assistant…. It checks git and GitHub CLI; step 1 (add a repository) uses the window's own registration
/// (#84). Nothing here runs a command for the user: install and login commands are only copied.
@MainActor
@Observable
final class SetupAssistantState {
    enum GitHubCheck: Equatable {
        case checking
        case done(GHStatusGuidance)
    }

    var isPresented = false
    /// `nil` while checking.
    private(set) var git: GitSetupStatus?
    private(set) var gitHub: GitHubCheck = .checking
    /// The checks in flight; tests await them.
    private(set) var gitTask: Task<Void, Never>?
    private(set) var gitHubTask: Task<Void, Never>?

    @ObservationIgnored private let gitChecker: any GitSetupChecking
    @ObservationIgnored private let ghChecker: any GHAuthChecking

    init(gitChecker: any GitSetupChecking, ghChecker: any GHAuthChecking) {
        self.gitChecker = gitChecker
        self.ghChecker = ghChecker
    }

    /// Opens the assistant and checks git and GitHub CLI again.
    func present() {
        isPresented = true
        checkGit()
        checkGitHub()
    }

    func dismiss() {
        isPresented = false
    }

    /// Check Again for git (after `xcode-select --install`).
    func checkGit() {
        gitTask?.cancel()
        git = nil
        let checker = gitChecker
        gitTask = Task { [weak self] in
            let status = await checker.check()
            guard !Task.isCancelled else { return }
            self?.git = status
        }
    }

    /// Check Again for GitHub CLI (after `gh auth login`). The GitHub step is optional.
    func checkGitHub() {
        gitHubTask?.cancel()
        gitHub = .checking
        let checker = ghChecker
        gitHubTask = Task { [weak self] in
            let status = await checker.authStatus()
            guard !Task.isCancelled else { return }
            self?.gitHub = .done(status.map(GHStatusGuidance.init(status:)) ?? GHStatusGuidance(checkFailed: nil))
        }
    }

    /// `Open Repository` is enabled once a repository is open and git is ready (screens.md S-07).
    func canFinish(hasRepository: Bool) -> Bool {
        hasRepository && (git?.isReady ?? false)
    }
}
