/// Reads which Gitea instances gt has local credentials for (ADR-0026 §2), before any Gitea repository is read. gt
/// answers from local state only; no request is made.
protocol GiteaInstanceChecking: Sendable {
    /// Instances gt reports `credential_available` for, with a valid https URL. Any failure (no gt, another tool named
    /// `gt`, an unsupported version, a timeout, output it cannot read) is empty: fail closed.
    func loggedInInstances() async -> [GiteaInstance]
}

/// The app's checker: `GTClient.loggedInInstances()` in gt's neutral folder. Only the instances come back.
struct LiveGiteaInstanceChecker: GiteaInstanceChecking {
    let client: GTClient

    static let live = LiveGiteaInstanceChecker(client: GTClient())

    func loggedInInstances() async -> [GiteaInstance] {
        (try? await client.loggedInInstances()) ?? []
    }
}
