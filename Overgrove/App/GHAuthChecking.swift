/// Reads whether GitHub CLI is installed and logged in (`gh auth status`, ADR-0004), for the setup assistant (S-07,
/// #85) and the status bar's gh field (#83).
protocol GHAuthChecking: Sendable {
    /// `nil` when the check itself failed or was cancelled; the caller shows that it could not check.
    func authStatus() async -> GHAuthStatus?
    /// github.com's state and the hosts gh is logged in to (ADR-0025 §1); `nil` like `authStatus()`.
    func authReport() async -> GHAuthReport?
}

extension GHAuthChecking {
    /// A checker that knows only github.com's state reports no other host.
    func authReport() async -> GHAuthReport? {
        await authStatus().map { GHAuthReport(status: $0, hosts: []) }
    }
}

/// The app's checker: `GHClient.authStatus()` in gh's neutral folder. Only the parsed state comes back.
struct LiveGHAuthChecker: GHAuthChecking {
    let client: GHClient

    static let live = LiveGHAuthChecker(client: GHClient())

    func authStatus() async -> GHAuthStatus? {
        try? await client.authStatus()
    }

    func authReport() async -> GHAuthReport? {
        try? await client.authReport()
    }
}
