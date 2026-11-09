import Foundation

/// The git Overgrove found, for the setup assistant's git step (S-07, #85).
enum GitSetupStatus: Equatable, Sendable {
    /// `path` is escaped for display.
    case ready(version: GitVersion, path: String)
    /// No developer tools: `xcode-select -p` found nothing, or the git there is missing.
    case missing
    case unsupported(found: GitVersion)
    /// The git chosen in Settings fails ADR-0019's rules (#106); both strings are escaped. Offer Use Default.
    case chosenRejected(path: String, reason: String)
    /// Any other failure, as a one-line escaped message.
    case failed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Finds git the way every query does (`GitEnvironment.discover`).
protocol GitSetupChecking: Sendable {
    func check() async -> GitSetupStatus
}

/// The app's checker: the shared client, which keeps a successful discovery and retries a failed one (so Check
/// Again sees newly installed tools).
struct LiveGitSetupChecker: GitSetupChecking {
    let client: @Sendable () async throws -> GitClient

    static let live = LiveGitSetupChecker(client: { try await LiveGitClient.shared.client() })

    func check() async -> GitSetupStatus {
        do {
            let environment = try await client().environment
            return .ready(
                version: environment.version, path: PathValidator.displayable(environment.executable.path))
        } catch let error as GitError {
            return Self.status(for: error)
        } catch {
            return .failed(String(localized: "Overgrove could not run git."))
        }
    }

    static func status(for error: GitError) -> GitSetupStatus {
        switch error {
        case .executableNotFound: .missing
        case .unsupportedVersion(let found): .unsupported(found: found)
        case .chosenExecutableRejected(let path, let reason): .chosenRejected(path: path, reason: reason)
        default: .failed(PathValidator.displayable(error.message))
        }
    }
}
