// STAND-IN(#85): copied verbatim from the open PR for #85 (shared gh guidance). Replace with #85's file when it merges.
/// Reads whether GitHub CLI is installed and logged in (`gh auth status`, ADR-0004), for the setup assistant (S-07,
/// #85) and the status bar's gh field (#83).
protocol GHAuthChecking: Sendable {
    /// `nil` when the check itself failed or was cancelled; the caller shows that it could not check.
    func authStatus() async -> GHAuthStatus?
}

/// The app's checker: `GHClient.authStatus()` in gh's neutral folder. Only the parsed state comes back.
struct LiveGHAuthChecker: GHAuthChecking {
    let client: GHClient

    static let live = LiveGHAuthChecker(client: GHClient())

    func authStatus() async -> GHAuthStatus? {
        try? await client.authStatus()
    }
}
