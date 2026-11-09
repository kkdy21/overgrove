/// Every failure the gt layer reports (ADR-0026 §4, §7). Screens show `message` only: gt's stderr is never shown or
/// logged, because a Gitea token (40 hex digits) cannot be told apart from a commit SHA by `CredentialMasker`.
enum GTError: Error, Sendable, Equatable {
    /// No gt at the fixed locations, or what is there does not print gt's version line (another tool named `gt`, such
    /// as Graphite's CLI).
    case notInstalled
    /// gt's version is older than the one Overgrove was checked against.
    case unsupportedVersion(found: String)
    /// gt has no usable credentials for this instance URL.
    case notLoggedIn(instance: String)
    case launchFailed(errno: Int32)
    case timeout(seconds: Int)
    case outputTruncated
    /// gt exited with this code. Its stderr is not kept.
    case failed(code: Int32)
    case parseFailed(parser: String)
    case cancelled

    var message: String {
        switch self {
        case .notInstalled: String(localized: "Gitea CLI (gt) is not installed.")
        case .unsupportedVersion(let found):
            String(
                localized:
                    "Gitea CLI \(found) is older than Overgrove supports (\(GTClient.minimumVersion.description) or later)."
            )
        case .notLoggedIn(let instance): String(localized: "Gitea CLI is not logged in to \(instance).")
        case .launchFailed(let code): String(localized: "Gitea CLI could not be started (error \(code)).")
        case .timeout(let seconds):
            String(localized: "Gitea CLI did not respond within \(seconds) seconds and was stopped.")
        case .outputTruncated: String(localized: "Too many or too large issues to show")
        case .failed(let code): String(localized: "Gitea CLI reported an error (exit code \(code)).")
        case .parseFailed: String(localized: "Overgrove could not understand Gitea CLI's output.")
        case .cancelled: ""
        }
    }
}
