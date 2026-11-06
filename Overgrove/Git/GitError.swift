import Foundation

/// Text derived from git or gh output that is safe to show and log.
///
/// The only way to create one is through `CredentialMasker`, so unmasked stderr cannot end up in an error, the UI,
/// or a log by accident (overview.md §6.2, threats T11/T16).
struct MaskedText: Sendable, Hashable {
    static let maximumLength = 64 * 1024
    static let summaryLength = 200

    /// Masked, control characters removed, at most 64 KiB.
    let text: String

    init(masking raw: Data) {
        self.init(masking: String(decoding: raw, as: UTF8.self))
    }

    init(masking raw: String) {
        let masked = CredentialMasker.mask(raw)
        let printable = String(
            String.UnicodeScalarView(
                masked.unicodeScalars.filter {
                    $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0)
                }
            )
        )
        text = printable.count > Self.maximumLength ? String(printable.prefix(Self.maximumLength)) : printable
    }

    /// First non-empty line, at most 200 characters, for one-line messages.
    var summary: String {
        let line = text.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > Self.summaryLength ? String(trimmed.prefix(Self.summaryLength - 1)) + "…" : trimmed
    }
}

/// Every failure the git layer reports (overview.md §6.1). Screens show `message`; they never parse stderr.
enum GitError: Error, Sendable, Equatable {
    case executableNotFound(path: String)
    case launchFailed(errno: Int32)
    case unsupportedVersion(found: GitVersion)
    case notARepository(detail: MaskedText)
    /// git refused a repository owned by another user. Overgrove never bypasses `safe.directory`.
    case dubiousOwnership(detail: MaskedText)
    case worktreeMissing(path: String)
    /// Repository configuration could not be inspected, so queries stop (fail closed, ADR-0009).
    case configInspectionFailed(reason: String)
    /// An argument failed validation before anything ran (T9).
    case invalidArgument(reason: String)
    /// A security rule blocked the operation, e.g. an `ext::` or `fd::` remote.
    case blockedBySecurityPolicy(detail: MaskedText)
    case timeout(seconds: Int)
    /// Output exceeded the limit. Warning level: callers may still show the partial result.
    case outputTruncated
    case authenticationFailed(detail: MaskedText)
    case networkUnavailable(detail: MaskedText)
    case nonZeroExit(code: Int32, detail: MaskedText)
    case parseFailed(parser: String, offset: Int)
    case cancelled

    // MARK: Classification

    /// Classifies a finished git process (git-command-catalog.md §6). Returns `nil` on success.
    ///
    /// Matching runs on masked stderr, case-insensitively; patterns assume `LC_ALL=C` English messages.
    static func classify(
        exitCode: Int32?,
        signal: Int32?,
        timedOut: Bool,
        outputTruncated: Bool,
        timeoutSeconds: Int,
        stderr: Data
    ) -> GitError? {
        if timedOut { return .timeout(seconds: timeoutSeconds) }
        if outputTruncated { return .outputTruncated }
        if exitCode == 0 { return nil }

        let detail = MaskedText(masking: stderr)
        let haystack = detail.text.lowercased()
        func matches(_ patterns: [String]) -> Bool { patterns.contains { haystack.contains($0) } }

        if matches(["detected dubious ownership"]) { return .dubiousOwnership(detail: detail) }
        if matches(["transport 'ext' not allowed", "transport 'fd' not allowed"]) {
            return .blockedBySecurityPolicy(detail: detail)
        }
        if matches([
            "authentication failed", "could not read username", "could not read password",
            "terminal prompts disabled", "permission denied (publickey", "host key verification failed",
            "invalid username or password",
        ]) {
            return .authenticationFailed(detail: detail)
        }
        if matches([
            "could not resolve host", "unable to look up", "connection refused", "connection timed out",
            "operation timed out", "network is unreachable",
        ]) {
            return .networkUnavailable(detail: detail)
        }
        if matches(["not a git repository"]) { return .notARepository(detail: detail) }
        // Killed by a signal we did not send: report like a shell does (128 + signal).
        let code = exitCode ?? (signal.map { 128 + $0 } ?? -1)
        return .nonZeroExit(code: code, detail: detail)
    }

    /// Maps a parser failure.
    init(_ error: ParseError) {
        self = .parseFailed(parser: error.parser, offset: error.offset)
    }

    // MARK: Presentation (v0.1 UI is English, ADR-0005)

    /// One-line message for the status bar, banners, and alerts.
    var message: String {
        switch self {
        case .executableNotFound:
            "git could not be found. Install the Xcode Command Line Tools."
        case .launchFailed(let code):
            "git could not be started (error \(code))."
        case .unsupportedVersion(let found):
            "Overgrove needs git \(GitVersion.minimumSupported) or later (found \(found))."
        case .notARepository:
            "This folder is not a Git repository."
        case .dubiousOwnership:
            "git refused this repository because another user owns it. Overgrove does not bypass this check."
        case .worktreeMissing:
            "The worktree folder no longer exists."
        case .configInspectionFailed:
            "Overgrove could not inspect this repository's configuration, so it stopped querying it."
        case .invalidArgument:
            "A name looked unsafe, so the command was not run."
        case .blockedBySecurityPolicy:
            "This remote uses a transport that Overgrove blocks for security."
        case .timeout(let seconds):
            "git did not respond within \(seconds) seconds and was stopped."
        case .outputTruncated:
            "The output was too large; only part of it is shown."
        case .authenticationFailed:
            "Authentication with the remote failed. Check your git credentials in Terminal."
        case .networkUnavailable:
            "The remote could not be reached."
        case .nonZeroExit(_, let detail):
            detail.summary.isEmpty ? "git reported an error." : detail.summary
        case .parseFailed:
            "Overgrove could not understand git's output. Please report this as a bug."
        case .cancelled:
            ""
        }
    }

    /// A command the user can copy and run themselves. Overgrove never runs it.
    var suggestedCommand: String? {
        switch self {
        case .executableNotFound: "xcode-select --install"
        case .worktreeMissing: "git worktree prune --dry-run"
        case .dubiousOwnership: "ls -ld <repository>  # check the owner; Overgrove will not add safe.directory"
        default: nil
        }
    }

    /// Masked stderr for the "Details" disclosure.
    var detail: MaskedText? {
        switch self {
        case .notARepository(let detail), .dubiousOwnership(let detail), .blockedBySecurityPolicy(let detail),
            .authenticationFailed(let detail), .networkUnavailable(let detail), .nonZeroExit(_, let detail):
            detail
        default:
            nil
        }
    }

    /// Whether a manual retry can help without changing anything.
    var isRetryable: Bool {
        switch self {
        case .timeout, .authenticationFailed, .networkUnavailable, .nonZeroExit, .configInspectionFailed: true
        default: false
        }
    }

    /// Hidden from the user (cancellation is not an error to them).
    var isSilent: Bool { self == .cancelled }

    /// Warning rather than failure: partial results may still be shown.
    var isWarning: Bool { self == .outputTruncated }
}
