import Foundation

/// What a failed fetch of one remote means for the user and what they can do about it (#78, interaction.md §4.2).
///
/// This is the model the fetch screens render; it holds no UI. Every text is written here, so the server can at most
/// pick which of these texts appears. Remote output is shown only as masked `detail`. Commands are for the user to
/// copy: Overgrove never runs them (overview.md §6.2).
struct FetchFailureGuidance: Sendable, Equatable {
    /// The four groups of interaction.md §4.2.
    enum Category: Sendable, Equatable, CaseIterable {
        case authentication, network, timeout, other
    }

    enum Reason: Sendable, Equatable {
        case credentialsRejected
        case sshKeyRejected
        case hostKeyNotTrusted
        case hostKeyChanged
        case accessDenied
        case hostUnreachable
        case timedOut(seconds: Int)
        case remoteNotFound
        case transportNotAllowed
        case blockedByConfiguration
        case noRemotes
        case unknown
    }

    /// `nil` only for `noRemotes`.
    let remote: RemoteName?
    let reason: Reason
    /// One line for the status bar, e.g. `Authentication failed for origin`.
    let summary: String
    /// What to do, for the Details view.
    let guidance: String
    /// Commands to show as copyable text. They use only the validated remote name and host, so they need no quoting.
    let commands: [String]
    /// Masked stderr, when git produced any.
    let detail: MaskedText?

    var category: Category {
        switch reason {
        case .credentialsRejected, .sshKeyRejected, .hostKeyNotTrusted, .hostKeyChanged, .accessDenied:
            .authentication
        case .hostUnreachable: .network
        case .timedOut: .timeout
        case .remoteNotFound, .transportNotAllowed, .blockedByConfiguration, .noRemotes, .unknown: .other
        }
    }

    /// The last few non-empty lines of `detail`, for the "other" Details view (interaction.md §4.2).
    var detailTail: String? {
        guard let detail else { return nil }
        let lines = detail.text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return nil }
        return lines.suffix(Self.detailTailLines).joined(separator: "\n")
    }

    static let detailTailLines = 5

    /// Shown when a repository has no remote to fetch.
    static let noRemotes = FetchFailureGuidance(
        remote: nil,
        reason: .noRemotes,
        summary: "No remotes configured",
        guidance: "This repository has no remote to fetch from. Add one in Terminal with \"git remote add\".",
        commands: [],
        detail: nil
    )

    /// Guidance for a failed fetch of `remote`. `nil` for cancellation, which is not a failure (interaction.md §4.2).
    ///
    /// - Parameter host: The remote's host, from `host(fromRemoteURL:)`, to name it in texts and commands.
    init?(error: GitError, remote: RemoteName, host: String? = nil) {
        guard error != .cancelled else { return nil }
        let content = Self.content(for: error, remote: remote.value, host: host)
        self.init(
            remote: remote,
            reason: content.reason,
            summary: content.summary,
            guidance: content.guidance,
            commands: content.commands,
            detail: error.detail
        )
    }

    private init(
        remote: RemoteName?,
        reason: Reason,
        summary: String,
        guidance: String,
        commands: [String],
        detail: MaskedText?
    ) {
        self.remote = remote
        self.reason = reason
        self.summary = summary
        self.guidance = guidance
        self.commands = commands
        self.detail = detail
    }

    // MARK: - Texts (v0.1 UI is English, ADR-0005)

    private struct Content {
        let reason: Reason
        let summary: String
        let guidance: String
        let commands: [String]
    }

    private static func content(for error: GitError, remote: String, host: String?) -> Content {
        let fetch = "git fetch \(remote)"
        switch error {
        case .authenticationFailed:
            return Content(
                reason: .credentialsRejected, summary: "Authentication failed for \(remote)",
                guidance: "Run \"\(fetch)\" in Terminal to check your credentials. Overgrove does not prompt for "
                    + "passwords; it uses the credentials your Git setup already stores.",
                commands: [fetch])
        case .sshAuthenticationFailed:
            return Content(
                reason: .sshKeyRejected, summary: "The SSH key was rejected for \(remote)",
                guidance: "The server did not accept any of your SSH keys. Add your key to the SSH agent (for example "
                    + "with \"ssh-add --apple-use-keychain\"), then run \"\(fetch)\" in Terminal.",
                commands: ["ssh-add -l", fetch])
        case .hostKeyVerificationFailed(let changed, _):
            return hostKey(changed: changed, remote: remote, host: host)
        case .accessDenied:
            return Content(
                reason: .accessDenied, summary: "Access to \(remote) was denied",
                guidance: "The remote accepted your credentials, but this account cannot read the repository. Check "
                    + "that you have access, or sign in with another account in Terminal.",
                commands: [fetch])
        case .networkUnavailable:
            return Content(
                reason: .hostUnreachable, summary: "Could not reach \(host ?? "the remote of \(remote)")",
                guidance: "Check your network connection, VPN, or proxy, then try again.", commands: [])
        case .timeout(let seconds):
            return Content(
                reason: .timedOut(seconds: seconds), summary: "Fetch timed out after \(seconds) s",
                guidance: "The remote \(remote) did not finish in time. Try again; for a very large repository, run "
                    + "\"\(fetch)\" once in Terminal.",
                commands: [fetch])
        case .remoteNotFound:
            return Content(
                reason: .remoteNotFound, summary: "The repository for \(remote) was not found",
                guidance: "Check the remote's URL. If the repository is private, missing access can look the same.",
                commands: ["git remote -v"])
        case .transportNotAllowed:
            return Content(
                reason: .transportNotAllowed, summary: "Overgrove does not fetch \(remote)",
                guidance: error.message + " You can still run \"\(fetch)\" in Terminal.", commands: [fetch])
        case .configInspectionFailed(let reason):
            // `reason` is always Overgrove's own text (RepoConfigInspector), never git output.
            return Content(
                reason: .blockedByConfiguration, summary: "Fetching \(remote) is turned off for this repository",
                guidance: reason, commands: [])
        case .nonZeroExit:
            // Not `error.message`: for this case it is the first stderr line, which a server can write over ssh.
            return Content(
                reason: .unknown, summary: "Fetch failed",
                guidance: "git reported an error. Run \"\(fetch)\" in Terminal to see the full error.",
                commands: [fetch])
        default:
            return Content(
                reason: .unknown, summary: "Fetch failed",
                guidance: error.message + " Run \"\(fetch)\" in Terminal to see the full error.", commands: [fetch])
        }
    }

    private static func hostKey(changed: Bool, remote: String, host: String?) -> Content {
        let name = host ?? "the remote of \(remote)"
        guard changed else {
            return Content(
                reason: .hostKeyNotTrusted, summary: "The SSH host key of \(name) is not trusted yet",
                guidance: "Overgrove never accepts host keys on its own. Run \"git fetch \(remote)\" in Terminal, "
                    + "compare the fingerprint with the one your Git host publishes, and accept it there.",
                commands: ["git fetch \(remote)"])
        }
        return Content(
            reason: .hostKeyChanged, summary: "The SSH host key of \(name) has changed",
            guidance: "This can mean someone is intercepting the connection. Do not remove the old key until you "
                + "have confirmed the new fingerprint with your Git host.",
            commands: host.map { ["ssh-keygen -F \($0)"] } ?? [])
    }

    // MARK: - Host

    /// The host of a remote URL, without user name, password, or port; `nil` for local paths, helper URLs, and
    /// anything that is not a plain host name. Safe to show and to put into a copyable command.
    ///
    /// Covers `<scheme>://[user[:password]@]host[:port]/…` and scp-style `[user@]host:path` (git's rule: a colon before
    /// the first slash, with no `::`).
    static func host(fromRemoteURL url: String) -> String? {
        guard TransportName.remoteHelper(forURL: url) == nil else { return nil }
        let authority: Substring
        if let separator = url.range(of: "://") {
            let rest = url[separator.upperBound...]
            authority = rest.prefix { $0 != "/" }
        } else if let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") {
            authority = url[..<colon]
        } else {
            return nil
        }
        // Drop credentials, then a port.
        let hostAndPort = authority.split(separator: "@", omittingEmptySubsequences: false).last ?? ""
        let host = hostAndPort.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return isHostName(host) ? String(host) : nil
    }

    /// Letters, digits, `.` and `-`, starting with a letter or digit, at most 253 characters.
    private static func isHostName(_ host: Substring) -> Bool {
        guard let first = host.unicodeScalars.first, host.utf8.count <= 253 else { return false }
        func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
            scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar))
        }
        return isAlphanumeric(first)
            && host.unicodeScalars.allSatisfy { isAlphanumeric($0) || $0 == "." || $0 == "-" }
    }
}
