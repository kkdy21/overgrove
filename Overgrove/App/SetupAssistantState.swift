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
    /// Why the folder last picked in step 1 was not added (#679). The window's alert sits behind this sheet until it
    /// closes, so while the assistant is open the reason is shown in step 1 instead. `nil` before a pick, once another
    /// folder is picked, and when the assistant opens again.
    private(set) var repositoryProblem: String?
    /// `nil` while checking.
    private(set) var git: GitSetupStatus?
    private(set) var gitHub: GitHubCheck = .checking
    /// The checks in flight; tests await them.
    private(set) var gitTask: Task<Void, Never>?
    private(set) var gitHubTask: Task<Void, Never>?

    @ObservationIgnored private let gitChecker: any GitSetupChecking
    @ObservationIgnored private let ghChecker: any GHAuthChecking
    /// Forgets the git chosen in Settings and drops the shared client (ADR-0019 §4, #106); `nil` hides Use Default.
    @ObservationIgnored private let useDefaultGitAction: (@MainActor () async -> Void)?
    /// Each GitHub CLI report this assistant reads, a failed one (`nil`) included, with when its check started: the
    /// app's status bar, accounts, and trusted hosts take it too, unless the app started a newer check (#488).
    @ObservationIgnored var onGitHubReport: (@MainActor (GHAuthReport?, ContinuousClock.Instant) -> Void)?

    init(
        gitChecker: any GitSetupChecking, ghChecker: any GHAuthChecking,
        useDefaultGit: (@MainActor () async -> Void)? = nil
    ) {
        self.gitChecker = gitChecker
        self.ghChecker = ghChecker
        self.useDefaultGitAction = useDefaultGit
    }

    var canUseDefaultGit: Bool { useDefaultGitAction != nil }

    /// Use Default, offered when the git chosen in Settings is refused: forget the choice, then check git again.
    func useDefaultGit() {
        guard let action = useDefaultGitAction else { return }
        gitTask?.cancel()
        git = nil
        let checker = gitChecker
        gitTask = Task { [weak self] in
            await action()
            guard !Task.isCancelled else { return }
            let status = await checker.check()
            guard !Task.isCancelled else { return }
            self?.git = status
        }
    }

    /// Opens the assistant and checks git and GitHub CLI again.
    func present() {
        isPresented = true
        repositoryProblem = nil
        checkGit()
        checkGitHub()
    }

    func dismiss() {
        isPresented = false
    }

    /// A folder was picked in step 1: the reason the previous one was refused goes away.
    func repositoryPicked() {
        repositoryProblem = nil
    }

    /// Shows why the picked folder was not added in step 1. Returns `false`, showing nothing, when the assistant is
    /// not open: the caller then uses the window's alert.
    func showRepositoryProblem(_ message: String) -> Bool {
        guard isPresented else { return false }
        repositoryProblem = message
        return true
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

    /// Check Again for GitHub CLI (after `gh auth login`). The GitHub step is optional. Every host gh is logged in to
    /// counts, not only github.com (#476).
    func checkGitHub() {
        gitHubTask?.cancel()
        gitHub = .checking
        let checker = ghChecker
        let started = ContinuousClock.now
        gitHubTask = Task { [weak self] in
            // The whole report, as the status bar reads it: a login only on another host counts too (#476).
            let report = await checker.authReport()
            guard !Task.isCancelled else { return }
            self?.gitHub = .done(report.map(GHStatusGuidance.init(report:)) ?? GHStatusGuidance(checkFailed: nil))
            self?.onGitHubReport?(report, started)
        }
    }

    /// `Open Repository` is enabled once a repository is open and git is ready (screens.md S-07).
    func canFinish(hasRepository: Bool) -> Bool {
        hasRepository && (git?.isReady ?? false)
    }
}
