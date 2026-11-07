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
    /// A security rule blocked the operation.
    case blockedBySecurityPolicy(detail: MaskedText)
    /// git refused a transport outside `GIT_ALLOW_PROTOCOL` or one set to `never` (`ext`, `fd`, a remote helper such
    /// as `codecommit`), #161. `transport` is `nil` unless git's message names a plain scheme.
    case transportNotAllowed(transport: String?, detail: MaskedText)
    case timeout(seconds: Int)
    /// Output exceeded the limit. Warning level: callers may still show the partial result.
    case outputTruncated
    /// The remote rejected the HTTPS credentials, or none were available without a prompt.
    case authenticationFailed(detail: MaskedText)
    /// The SSH server rejected every key (`Permission denied (publickey)`), #78.
    case sshAuthenticationFailed(detail: MaskedText)
    /// ssh refused the server's host key: unknown (`changed == false`) or different from `known_hosts`, #78.
    case hostKeyVerificationFailed(changed: Bool, detail: MaskedText)
    /// Authenticated but not allowed to read the repository (HTTP 403), #78.
    case accessDenied(detail: MaskedText)
    /// The remote repository does not exist, or the remote name is not configured (HTTP 404, missing path), #78.
    case remoteNotFound(detail: MaskedText)
    case networkUnavailable(detail: MaskedText)
    /// A query needed an object a partial clone does not have. Queries never lazy-fetch it (#212).
    case partialCloneObjectMissing(detail: MaskedText)
    /// The worktree's branch shares no history with the comparison base (`fatal: no merge base found`, #157).
    case noMergeBase
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
        // Only lines from local git and ssh count. Over HTTP the server's own text arrives as `remote:` lines; it must
        // not be able to choose the category, or hide the real error behind another one (#78).
        let localLines = detail.text.split(separator: "\n").filter { !$0.hasPrefix("remote:") }
        if let error = classify(localLines: localLines, detail: detail) { return error }
        // Killed by a signal we did not send: report like a shell does (128 + signal).
        let code = exitCode ?? (signal.map { 128 + $0 } ?? -1)
        return .nonZeroExit(code: code, detail: detail)
    }

    /// Matches local stderr lines against `LC_ALL=C` patterns (git-command-catalog.md §6). Order matters: the more
    /// specific cause wins, e.g. a changed host key before an unknown one.
    private static func classify(localLines: [Substring], detail: MaskedText) -> GitError? {
        let haystack = localLines.joined(separator: "\n").lowercased()
        func matches(_ patterns: [String]) -> Bool { patterns.contains { haystack.contains($0) } }

        // First: only the local ssh client prints this banner. If ssh was configured to carry on anyway, the server
        // could follow it with text that mimics another category; the warning must not be hidden behind it.
        if matches(["remote host identification has changed"]) {
            return .hostKeyVerificationFailed(changed: true, detail: detail)
        }
        if matches(["detected dubious ownership"]) { return .dubiousOwnership(detail: detail) }
        // Before the transport refusal: on git < 2.44 a blocked lazy fetch reports `transport 'file' not allowed`
        // too, but the cause the user needs is the missing object (#212).
        if matches(["lazy fetching disabled", "from promisor remote"]) {
            return .partialCloneObjectMissing(detail: detail)
        }
        if let name = refusedTransport(in: localLines) {
            // The name comes from repository configuration: echo only a plain scheme name of at most 64 characters.
            let isEchoable = name.count <= 64 && TransportName.isSchemeName(name)
            return .transportNotAllowed(transport: isEchoable ? String(name) : nil, detail: detail)
        }
        if matches(["host key verification failed"]) {
            return .hostKeyVerificationFailed(changed: false, detail: detail)
        }
        // ssh lists the methods it tried; a local file error says "Permission denied" without them.
        if matches(Self.sshMethods.map { "permission denied (\($0)" }) {
            return .sshAuthenticationFailed(detail: detail)
        }
        if matches([
            "authentication failed", "could not read username", "could not read password",
            "terminal prompts disabled", "invalid username or password", "returned error: 401",
        ]) {
            return .authenticationFailed(detail: detail)
        }
        if matches(["returned error: 403"]) { return .accessDenied(detail: detail) }
        if matches(["returned error: 404", "does not appear to be a git repository"])
            || localLines.contains(where: { $0.hasPrefix("fatal: repository '") && $0.hasSuffix("' not found") })
        {
            return .remoteNotFound(detail: detail)
        }
        if matches([
            "could not resolve host", "unable to look up", "connection refused", "connection timed out",
            "operation timed out", "network is unreachable", "no route to host", "failed to connect to",
            "couldn't connect to server", "connection reset by peer",
        ]) {
            return .networkUnavailable(detail: detail)
        }
        if matches(["not a git repository"]) { return .notARepository(detail: detail) }
        // git's own line only: a file or ref name in another message must not turn into this category.
        if localLines.contains(where: { $0 == "fatal: no merge base found" }) { return .noMergeBase }
        return nil
    }

    /// OpenSSH authentication method names, as printed in `Permission denied (<methods>).`
    private static let sshMethods = ["publickey", "password", "keyboard-interactive", "hostbased", "gssapi"]

    /// The name in git's own refusal line, `fatal: transport '<name>' not allowed` (possibly empty).
    ///
    /// Only a whole line that starts with `fatal:` counts, so a server cannot fake a refusal, and hide the real error,
    /// with a `remote:` progress line.
    private static func refusedTransport(in lines: [Substring]) -> Substring? {
        let prefix = "fatal: transport '"
        let suffix = "' not allowed"
        for line in lines {
            guard line.hasPrefix(prefix), line.hasSuffix(suffix), line.count >= prefix.count + suffix.count else {
                continue
            }
            return line.dropFirst(prefix.count).dropLast(suffix.count)
        }
        return nil
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
        case .transportNotAllowed(let transport, _):
            (transport.map { "Overgrove does not fetch remotes that use the '\($0)' transport." }
                ?? "This remote uses a transport that Overgrove does not allow.")
                + " Only https, ssh, git, http, and local file remotes can be fetched."
        case .timeout(let seconds):
            "git did not respond within \(seconds) seconds and was stopped."
        case .outputTruncated:
            "The output was too large; only part of it is shown."
        case .authenticationFailed:
            "Authentication with the remote failed. Check your git credentials in Terminal."
        case .sshAuthenticationFailed:
            "The server rejected your SSH key. Check your SSH agent in Terminal."
        case .hostKeyVerificationFailed(let changed, _):
            changed
                ? "The server's SSH host key has changed. Verify it before trusting the new key."
                : "The server's SSH host key is not trusted yet. Connect once in Terminal to verify it."
        case .accessDenied:
            "The remote denied access to this repository."
        case .remoteNotFound:
            "The remote repository was not found."
        case .networkUnavailable:
            "The remote could not be reached."
        case .partialCloneObjectMissing:
            "This repository is a partial clone and does not have this content locally. Overgrove does not download "
                + "missing objects."
        case .noMergeBase:
            "This branch shares no history with the base branch, so there is nothing to compare."
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
            .transportNotAllowed(_, let detail), .authenticationFailed(let detail),
            .sshAuthenticationFailed(let detail),
            .hostKeyVerificationFailed(_, let detail), .accessDenied(let detail), .remoteNotFound(let detail),
            .networkUnavailable(let detail), .partialCloneObjectMissing(let detail), .nonZeroExit(_, let detail):
            detail
        default:
            nil
        }
    }

    /// Whether a manual retry can help without changing anything.
    var isRetryable: Bool {
        switch self {
        case .timeout, .authenticationFailed, .sshAuthenticationFailed, .networkUnavailable, .nonZeroExit,
            .configInspectionFailed:
            true
        default: false
        }
    }

    /// Hidden from the user (cancellation is not an error to them).
    var isSilent: Bool { self == .cancelled }

    /// Warning rather than failure: partial results may still be shown.
    var isWarning: Bool { self == .outputTruncated }
}
