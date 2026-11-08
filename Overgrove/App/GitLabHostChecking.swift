/// Asks glab whether it is logged in to one host (ADR-0026 §2), before any GitLab project on that host is read.
protocol GitLabHostChecking: Sendable {
    /// `true` only when glab reports `host` logged in. Any failure (no glab, no configuration, an unsupported version,
    /// a timeout, output it cannot read) is `false`: fail closed.
    func isLoggedIn(_ host: RemoteHost) async -> Bool
}

/// The app's checker: `GLClient.hostStatus(_:)` in glab's neutral folder. Only the answer comes back.
struct LiveGitLabHostChecker: GitLabHostChecking {
    let client: GLClient

    static let live = LiveGitLabHostChecker(client: GLClient())

    func isLoggedIn(_ host: RemoteHost) async -> Bool {
        (try? await client.hostStatus(host))?.isLoggedIn ?? false
    }
}
