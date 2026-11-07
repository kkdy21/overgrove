// STAND-IN(#85): copied verbatim from the open PR for #85 (shared gh guidance). Replace with #85's file when it merges.
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
