/// What the app says about GitHub CLI's state, shared by the setup assistant (S-07, #85) and the issues panel (#83).
///
/// Every text is written here and localized (#454); the commands stay as typed. The command is for the user to copy into Terminal; Overgrove never runs `gh auth
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
            title = String(localized: "Logged in as @\(PathValidator.displayable(login))")
            message = nil
            command = nil
            isOK = true
        case .notLoggedIn:
            title = String(localized: "Not logged in")
            message = String(localized: "Run this in Terminal, then check again:")
            command = "gh auth login"
            isOK = false
        case .notInstalled:
            title = String(localized: "GitHub CLI is not installed")
            message = String(localized: "Install GitHub CLI to see issues, then check again:")
            command = "brew install gh"
            isOK = false
        }
    }

    /// The check could not run (`gh` failed in another way). `detail` must already be escaped for display.
    init(checkFailed detail: String?) {
        title = String(localized: "Couldn't check GitHub CLI")
        message = detail
        command = nil
        isOK = false
    }

    /// Shown under the GitHub step and wherever gh is set up.
    static var tokenNote: String { String(localized: "Overgrove never asks for or stores tokens.") }
}
