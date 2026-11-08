/// What the app says about GitHub CLI's state, shared by the setup assistant (S-07, #85) and the issues panel (#83).
///
/// Every text is written here. The command is for the user to copy into Terminal; Overgrove never runs `gh auth
/// login` or `brew install gh` itself (screens.md S-07, ADR-0004 §4), and never asks for or stores tokens.
struct GHStatusGuidance: Equatable, Sendable {
    /// One line: `Logged in as @mina-dev`, `Not logged in`, …
    let title: String
    /// What to do, or `nil` when nothing is needed.
    let message: String?
    /// A command to copy, e.g. `gh auth login`.
    let command: String?
    let isOK: Bool

    init(status: GHAuthStatus) {
        switch status {
        case .loggedIn(let login):
            title = "Logged in as @\(PathValidator.displayable(login))"
            message = nil
            command = nil
            isOK = true
        case .notLoggedIn:
            title = "Not logged in"
            message = "Run this in Terminal, then check again:"
            command = "gh auth login"
            isOK = false
        case .notInstalled:
            title = "GitHub CLI is not installed"
            message = "Install GitHub CLI to see issues, then check again:"
            command = "brew install gh"
            isOK = false
        }
    }

    /// From the whole report (#476), as the status bar reads it: github.com's state, or, when only other hosts have a
    /// working login (the report lists only those, #467), a ready state that names where gh is logged in.
    init(report: GHAuthReport) {
        let others = report.hosts.subtracting([GitHubRepository.publicHost]).sorted { $0.name < $1.name }
        guard report.status == .notLoggedIn, let first = others.first else {
            self.init(status: report.status)
            return
        }
        let title: String
        if others.count > 1 {
            title = "Logged in to \(first.name) and \(others.count - 1) more host" + (others.count > 2 ? "s" : "")
        } else if let account = report.accounts[first] {
            title = "Logged in to \(first.name) as @\(PathValidator.displayable(account.login))"
        } else {
            title = "Logged in to \(first.name)"
        }
        self.init(
            title: title,
            message: "Not logged in to github.com. Issues appear for repositories on the hosts gh is logged in to.",
            command: nil, isOK: true)
    }

    private init(title: String, message: String?, command: String?, isOK: Bool) {
        self.title = title
        self.message = message
        self.command = command
        self.isOK = isOK
    }

    /// The check could not run (`gh` failed in another way). `detail` must already be escaped for display.
    init(checkFailed detail: String?) {
        title = "Couldn't check GitHub CLI"
        message = detail
        command = nil
        isOK = false
    }

    /// Shown under the GitHub step and wherever gh is set up.
    static let tokenNote = "Overgrove never asks for or stores tokens."
}
