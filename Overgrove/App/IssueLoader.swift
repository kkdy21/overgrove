/// The outcome of reading a repository's open issues (S-06, #81).
enum IssueLoadResult: Sendable, Equatable {
    case issues([Issue])
    case notInstalled
    case notLoggedIn
    /// A one-line message built from `GHError.message` (masked stderr at most), not yet escaped.
    case failed(String)
    case cancelled
}

/// Reads open issues through `GHClient` (git-command-catalog.md §5). gh runs in its neutral folder, never in the
/// repository; only the parsed issues come back.
protocol IssueLoading: Sendable {
    func issues(in repository: GitHubRepository) async -> IssueLoadResult
}

struct LiveIssueLoader: IssueLoading {
    let client: GHClient

    static let live = LiveIssueLoader(client: GHClient())

    func issues(in repository: GitHubRepository) async -> IssueLoadResult {
        do {
            return .issues(try await client.issues(in: repository))
        } catch let error as GHError {
            switch error {
            case .notInstalled: return .notInstalled
            case .notLoggedIn: return .notLoggedIn
            case .cancelled: return .cancelled
            default: return .failed(error.message)
            }
        } catch {
            return .cancelled
        }
    }
}
