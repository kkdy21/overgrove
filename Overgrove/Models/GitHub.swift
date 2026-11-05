import Foundation

/// `gh` login state (parsing-spec.md §10.1). The app never sees the token itself.
enum GHAuthStatus: Sendable, Hashable {
    case notInstalled
    case notLoggedIn
    case loggedIn(login: String)
}

/// A GitHub issue from `gh issue list --json` (parsing-spec.md §10.2).
struct Issue: Sendable, Hashable, Identifiable {
    enum State: String, Sendable, Hashable {
        case open = "OPEN"
        case closed = "CLOSED"
    }

    struct Label: Sendable, Hashable {
        let name: String
        /// Hex color without `#`, as returned by GitHub.
        let color: String?
    }

    let number: Int
    let title: String
    let state: State
    let labels: [Label]
    let assignees: [String]
    let updatedAt: Date
    let url: URL

    var id: Int { number }
}
