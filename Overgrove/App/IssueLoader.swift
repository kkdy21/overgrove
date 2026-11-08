/// The outcome of reading a repository's open issues (S-06, #81).
enum IssueLoadResult: Sendable, Equatable {
    case issues([Issue])
    case notInstalled
    case notLoggedIn
    /// A one-line message built from `GHError.message` (masked stderr at most), not yet escaped.
    case failed(String)
    case cancelled
}

/// Reads open issues through `GHClient` or `GLClient` (git-command-catalog.md §5, §5.1). Each CLI runs in its neutral
/// folder, never in the repository; only the parsed issues come back.
protocol IssueLoading: Sendable {
    func issues(in source: IssueSource) async -> IssueLoadResult
}

struct LiveIssueLoader: IssueLoading {
    let client: GHClient
    let gitlab: GLClient

    static let live = LiveIssueLoader(client: GHClient(), gitlab: GLClient())

    func issues(in source: IssueSource) async -> IssueLoadResult {
        switch source {
        case .github(let repository): await issues(in: repository)
        case .gitlab(let project): await issues(in: project)
        }
    }

    private func issues(in project: GitLabProject) async -> IssueLoadResult {
        do {
            return .issues(try await gitlab.issues(in: project))
        } catch GLError.cancelled {
            return .cancelled
        } catch let error as GLError {
            // The host was trusted a moment ago (ADR-0026 §2); whatever glab says now is reported as is. Its stderr is
            // never part of the message (ADR-0026 §4).
            return .failed(error.message)
        } catch {
            return .cancelled
        }
    }

    private func issues(in repository: GitHubRepository) async -> IssueLoadResult {
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
