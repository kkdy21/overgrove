/// Every failure the glab layer reports (ADR-0026 §4, §7). Screens show `message` only: glab's stderr is never shown or
/// logged, because `CredentialMasker` does not know GitLab's token formats.
enum GLError: Error, Sendable, Equatable {
    /// No glab at the fixed locations, or what is there does not print glab's version line (another tool's `glab`).
    case notInstalled
    /// glab's version is older than the one Overgrove was checked against.
    case unsupportedVersion(found: String)
    /// glab has no configuration file yet: running it would create one in the user's folder (ADR-0026 §6).
    case notSetUp
    /// glab does not report this host as logged in.
    case notLoggedIn(host: String)
    case launchFailed(errno: Int32)
    case timeout(seconds: Int)
    case outputTruncated
    /// glab exited with this code. Its stderr is not kept.
    case failed(code: Int32)
    case parseFailed(parser: String)
    case cancelled

    var message: String {
        switch self {
        case .notInstalled: String(localized: "GitLab CLI (glab) is not installed.")
        case .unsupportedVersion(let found):
            String(
                localized:
                    "GitLab CLI \(found) is older than Overgrove supports (\(GLClient.minimumVersion.description) or later)."
            )
        case .notSetUp: String(localized: "GitLab CLI is not set up yet. Run glab once in Terminal.")
        case .notLoggedIn(let host): String(localized: "GitLab CLI is not logged in to \(host).")
        case .launchFailed(let code): String(localized: "GitLab CLI could not be started (error \(code)).")
        case .timeout(let seconds):
            String(localized: "GitLab CLI did not respond within \(seconds) seconds and was stopped.")
        case .outputTruncated: String(localized: "Too many or too large issues to show")
        case .failed(let code): String(localized: "GitLab CLI reported an error (exit code \(code)).")
        case .parseFailed: String(localized: "Overgrove could not understand GitLab CLI's output.")
        case .cancelled: ""
        }
    }
}
