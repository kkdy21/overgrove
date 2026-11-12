import Foundation

/// What a failed fetch of one remote means for the user and what they can do about it (#78, interaction.md §4.2).
///
/// This is the model the fetch screens render; it holds no UI. Every text is written here, so the server can at most
/// pick which of these texts appears. Remote output is shown only as masked `detail`. Commands are for the user to
/// copy: Overgrove never runs them (overview.md §6.2).
///
/// Terminal git is not hardened like Overgrove's: it runs the repository's hooks and its own `core.sshCommand`,
/// proxies, credential helpers, and pager. So a git command is offered only when the repository's configuration
/// report is clean, and the text always says to do it only for a trusted repository. Otherwise only commands that do
/// not read the repository are offered (`ssh-add`, `ssh-keyscan`, `ssh-keygen -F`), because a hostile repository
/// could otherwise fail a fetch on purpose to get its payload pasted into Terminal (security review of #200).
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

    /// `nil` for `noRemotes` and an unreadable configuration.
    let remote: RemoteName?
    let reason: Reason
    /// One line for the status bar, e.g. `Authentication failed for origin`.
    let summary: String
    /// What to do, for the Details view.
    let guidance: String
    /// Commands to show as copyable text. They use only the validated remote name, host, and port, so they need no
    /// further quoting.
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
    ///
    /// `MaskedText` has already kept only the last state of each rewritten progress line. Each line here is cut to
    /// `maximumDetailLineScalars` Unicode scalars, not `Character`s, which a run of combining marks can make any length:
    /// the server writes this text, so it does not decide how much the Details view lays out (#362).
    var detailTail: String? {
        guard let detail else { return nil }
        let lines = detail.text.unicodeScalars.split(separator: "\n").map(String.UnicodeScalarView.init).filter {
            !String($0).trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !lines.isEmpty else { return nil }
        return lines.suffix(Self.detailTailLines).map { line in
            line.count > Self.maximumDetailLineScalars
                ? String(line.prefix(Self.maximumDetailLineScalars)) + "…" : String(line)
        }.joined(separator: "\n")
    }

    static let detailTailLines = 5
    /// Longest line in `detailTail`, in Unicode scalars (#362).
    static let maximumDetailLineScalars = 300

    /// Shown when a repository has no remote to fetch.
    static let noRemotes = FetchFailureGuidance(
        remote: nil,
        reason: .noRemotes,
        summary: String(localized: "No remotes configured"),
        guidance: String(
            localized: "This repository has no remote to fetch from. Add one in Terminal with \"git remote add\"."),
        commands: [],
        detail: nil
    )

    /// Shown when the repository's configuration could not be read before fetching, so no remote is known (#77). No
    /// command is offered: nothing is known about the repository's settings.
    init(configurationError error: GitError) {
        self.init(
            remote: nil,
            reason: .unknown,
            summary: String(localized: "Could not read the repository's configuration"),
            guidance: String(
                localized:
                    "Overgrove could not read this repository's configuration, so it did not fetch. Refresh (⌘R) to try again."
            ),
            commands: [],
            detail: error.detail
        )
    }

    /// The git in use is too old to fetch `remote` (a remote on this Mac before `lazyFetchControlVersion`, #361). The
    /// summary names the git, not the repository, as the cause (#383). No command is offered.
    init(gitVersionLimitFor remote: RemoteName, reason: String) {
        self.init(
            remote: remote,
            reason: .blockedByConfiguration,
            summary: String(localized: "Overgrove does not fetch \(remote.value) with this git"),
            guidance: SafetyReason.display(reason),
            commands: [],
            detail: nil
        )
    }

    /// Guidance for a failed fetch of `remote`. `nil` for cancellation, which is not a failure (interaction.md §4.2).
    ///
    /// - Parameters:
    ///   - endpoint: Where the remote points, from `Endpoint(remoteURL:)`, to name the host in texts and commands.
    ///   - report: The repository's configuration report. Any finding means Terminal git would run settings that
    ///     Overgrove turned off, so no git command is offered.
    ///   - hookExecutables: Executable files in the repository's hooks directory (`hookExecutables(in:)`), which
    ///     Terminal git would run too. Any of them also withholds the command (#354, as the slow status hint, #168).
    init?(
        error: GitError, remote: RemoteName, endpoint: Endpoint? = nil, report: RepoSecurityReport,
        hookExecutables: [String]
    ) {
        guard error != .cancelled else { return nil }
        let terminal = Terminal(
            remote: remote.value, isRepositoryClean: report.findings.isEmpty && hookExecutables.isEmpty)
        let content = Self.content(for: error, terminal: terminal, endpoint: endpoint)
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

    /// Advice about running git in Terminal, which depends on whether the repository's configuration is clean.
    private struct Terminal {
        let remote: String
        let isRepositoryClean: Bool

        var fetch: String { "git fetch \(remote)" }
        /// `[git fetch <remote>]` for a clean repository, otherwise nothing.
        var fetchCommand: [String] { isRepositoryClean ? [fetch] : [] }

        /// A sentence that sends the user to Terminal for `purpose`, with the matching warning.
        func advice(_ purpose: String) -> String {
            guard isRepositoryClean else {
                return String(
                    localized:
                        "This repository has settings or hooks that Overgrove turned off for safety (see its security report). Terminal git would apply them, so review them before you run git in this repository."
                )
            }
            return String(
                localized:
                    "Run \"\(fetch)\" in Terminal \(purpose). Terminal git also runs the repository's own hooks and settings, which Overgrove turns off, so do this only for a repository you trust."
            )
        }
    }

    private static func content(for error: GitError, terminal: Terminal, endpoint: Endpoint?) -> Content {
        let remote = terminal.remote
        switch error {
        case .authenticationFailed:
            return Content(
                reason: .credentialsRejected, summary: String(localized: "Authentication failed for \(remote)"),
                guidance: String(
                    localized:
                        "Overgrove does not prompt for passwords; it uses the credentials your Git setup already stores."
                )
                    + " " + terminal.advice(String(localized: "to check your credentials")),
                commands: terminal.fetchCommand)
        case .sshAuthenticationFailed:
            return Content(
                reason: .sshKeyRejected, summary: String(localized: "The SSH key was rejected for \(remote)"),
                guidance: String(
                    localized:
                        "The server did not accept any of your SSH keys. Check that your key is loaded in the SSH agent (\"ssh-add -l\"; add it with \"ssh-add --apple-use-keychain\")."
                ) + " " + terminal.advice(String(localized: "to try again")),
                commands: ["ssh-add -l"] + terminal.fetchCommand)
        case .hostKeyVerificationFailed(let changed, _):
            return hostKey(changed: changed, terminal: terminal, endpoint: endpoint)
        case .accessDenied:
            return Content(
                reason: .accessDenied, summary: String(localized: "Access to \(remote) was denied"),
                guidance: String(
                    localized:
                        "The remote accepted your credentials, but this account cannot read the repository. Check that you have access, or sign in with another account."
                ) + " " + terminal.advice(String(localized: "to try again")),
                commands: terminal.fetchCommand)
        case .networkUnavailable:
            return Content(
                reason: .hostUnreachable,
                summary: String(
                    localized: "Could not reach \(endpoint?.host ?? String(localized: "the remote of \(remote)"))"),
                guidance: String(localized: "Check your network connection, VPN, or proxy, then try again."),
                commands: [])
        case .timeout(let seconds):
            return Content(
                reason: .timedOut(seconds: seconds), summary: String(localized: "Fetch timed out after \(seconds) s"),
                guidance: String(localized: "The remote \(remote) did not finish in time. Try again.") + " "
                    + terminal.advice(String(localized: "once if the repository is very large")),
                commands: terminal.fetchCommand)
        case .remoteNotFound:
            let list = "git --no-pager remote -v"
            let listAdvice =
                terminal.isRepositoryClean
                ? " "
                    + String(
                        localized:
                            "To list the configured URLs, run \"\(list)\" in Terminal; do this only for a repository you trust."
                    )
                : ""
            return Content(
                reason: .remoteNotFound, summary: String(localized: "The repository for \(remote) was not found"),
                guidance: String(
                    localized: "Check the remote's URL. If the repository is private, missing access can look the same."
                )
                    + listAdvice,
                commands: terminal.isRepositoryClean ? [list] : [])
        case .transportNotAllowed:
            return Content(
                reason: .transportNotAllowed, summary: String(localized: "Overgrove does not fetch \(remote)"),
                guidance: error.message + " " + terminal.advice(String(localized: "to fetch it yourself")),
                commands: terminal.fetchCommand)
        case .configInspectionFailed(let reason):
            // `reason` is always Overgrove's own text (RepoConfigInspector), never git output.
            return Content(
                reason: .blockedByConfiguration,
                summary: String(localized: "Fetching \(remote) is turned off for this repository"),
                guidance: SafetyReason.display(reason), commands: [])
        case .nonZeroExit:
            // Not `error.message`: for this case it is the first stderr line, which a server can write over ssh.
            return Content(
                reason: .unknown, summary: String(localized: "Fetch failed"),
                guidance: String(localized: "git reported an error; Details show the end of its output.") + " "
                    + terminal.advice(String(localized: "to see the full error")),
                commands: terminal.fetchCommand)
        default:
            return Content(
                reason: .unknown, summary: String(localized: "Fetch failed"),
                guidance: error.message + " " + terminal.advice(String(localized: "to see the full error")),
                commands: terminal.fetchCommand)
        }
    }

    private static func hostKey(changed: Bool, terminal: Terminal, endpoint: Endpoint?) -> Content {
        let name = endpoint?.host ?? String(localized: "the remote of \(terminal.remote)")
        // Repository-independent and read-only: prints the fingerprint the server presents now.
        let scan = endpoint.map { ["\($0.sshKeyscan) | ssh-keygen -lf -"] } ?? []
        guard changed else {
            return Content(
                reason: .hostKeyNotTrusted,
                summary: String(localized: "The SSH host key of \(name) is not trusted yet"),
                guidance: String(
                    localized:
                        "Overgrove never accepts host keys on its own. Compare the server's fingerprint with the one your Git host publishes, then accept the key outside Overgrove."
                ) + " " + terminal.advice(String(localized: "to connect and accept it")),
                commands: scan + terminal.fetchCommand)
        }
        return Content(
            reason: .hostKeyChanged, summary: String(localized: "The SSH host key of \(name) has changed"),
            guidance: String(
                localized:
                    "This can mean someone is intercepting the connection. Do not remove the old key until you have confirmed the new fingerprint with your Git host. A host alias in your SSH config may be stored under its alias instead of this name."
            ),
            commands: (endpoint.map { ["ssh-keygen -F \($0.knownHostsName)"] } ?? []) + scan)
    }

    // MARK: - Endpoint

    /// Where a remote points, reduced to what is safe to show and to put into a copyable command: a plain host name
    /// and a port, never a user name, password, or path.
    struct Endpoint: Sendable, Equatable {
        let host: String
        /// `nil` for the default port.
        let port: Int?

        /// Parses `<scheme>://[user[:password]@]host[:port][/?#…]` and scp-style `[user@]host:path` (git's rule: a
        /// colon before the first slash, with no `::`). `nil` for local paths, helper URLs, and anything that is not
        /// a plain host name.
        init?(remoteURL url: String) {
            guard TransportName.remoteHelper(forURL: url) == nil else { return nil }
            let authority: Substring
            if let separator = url.range(of: "://") {
                // The authority ends at the first `/`, `?`, or `#`, as curl reads it (security review of #200).
                authority = url[separator.upperBound...].prefix { !"/?#".contains($0) }
            } else if let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") {
                authority = url[..<colon]
            } else {
                return nil
            }
            // Credentials end at the last `@`; a password may contain `@` itself.
            let hostAndPort = authority.split(separator: "@", omittingEmptySubsequences: false).last ?? ""
            let parts = hostAndPort.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard let host = parts.first, Self.isHostName(host) else { return nil }
            var port: Int?
            if parts.count == 2 {
                guard let value = Int(parts[1]), parts[1].allSatisfy(\.isASCII), (1...65535).contains(value) else {
                    return nil
                }
                port = value == 22 ? nil : value
            }
            self.host = String(host)
            self.port = port
        }

        /// `ssh-keyscan [-p <port>] <host>`.
        var sshKeyscan: String { port.map { "ssh-keyscan -p \($0) \(host)" } ?? "ssh-keyscan \(host)" }

        /// The `known_hosts` name: `host`, or `'[host]:port'` for another port (quoted for the shell).
        var knownHostsName: String { port.map { "'[\(host)]:\($0)'" } ?? host }

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
}
