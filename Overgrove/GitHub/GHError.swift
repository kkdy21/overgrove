/// Every failure the gh layer reports. Screens show `message`; they never parse gh's stderr.
///
/// Kept apart from `GitError` because a gh problem only disables the issue panel (ADR-0004 §4) and needs different
/// guidance. A missing or logged-out gh during `authStatus()` is a state (`GHAuthStatus`), not an error.
enum GHError: Error, Sendable, Equatable {
    /// No gh at the fixed locations (`/opt/homebrew/bin/gh`, `/usr/local/bin/gh`).
    case notInstalled
    /// gh exited with code 4: the command needs authentication.
    case notLoggedIn
    case launchFailed(errno: Int32)
    /// An argument or environment value failed validation before anything ran (T9).
    case invalidArgument(reason: String)
    case timeout(seconds: Int)
    /// JSON cannot be read partially, so truncated output is a failure here, not a warning.
    case outputTruncated
    case nonZeroExit(code: Int32, detail: MaskedText)
    case parseFailed(parser: String, offset: Int)
    case cancelled

    init(_ error: ParseError) {
        self = .parseFailed(parser: error.parser, offset: error.offset)
    }

    /// One-line message for the issue panel (v0.1 UI is English, ADR-0005).
    var message: String {
        switch self {
        case .notInstalled:
            String(localized: "GitHub CLI (gh) is not installed, so the issue panel is off.")
        case .notLoggedIn:
            String(localized: "GitHub CLI is not logged in. Run `gh auth login` in Terminal.")
        case .launchFailed(let code):
            String(localized: "GitHub CLI could not be started (error \(code)).")
        case .invalidArgument:
            "A name looked unsafe, so gh was not run."
        case .timeout(let seconds):
            String(localized: "GitHub CLI did not respond within \(seconds) seconds and was stopped.")
        case .outputTruncated:
            String(localized: "GitHub CLI returned more data than Overgrove accepts.")
        case .nonZeroExit(_, let detail):
            detail.summary.isEmpty ? String(localized: "GitHub CLI reported an error.") : detail.summary
        case .parseFailed:
            String(localized: "Overgrove could not understand gh's output. Please report this as a bug.")
        case .cancelled:
            ""
        }
    }

    /// A command the user can copy and run themselves. Overgrove never runs it (ADR-0004 §5).
    var suggestedCommand: String? {
        switch self {
        case .notInstalled: "brew install gh"
        case .notLoggedIn: "gh auth login"
        default: nil
        }
    }

    /// Masked stderr for the "Details" disclosure.
    var detail: MaskedText? {
        if case .nonZeroExit(_, let detail) = self { return detail }
        return nil
    }

    /// Whether a manual retry can help without changing anything.
    var isRetryable: Bool {
        switch self {
        case .timeout, .nonZeroExit: true
        default: false
        }
    }

    /// Hidden from the user (cancellation is not an error to them).
    var isSilent: Bool { self == .cancelled }
}
