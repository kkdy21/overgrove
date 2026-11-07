/// A branch's relation to its upstream (status headers, parsing-spec.md §3.1; `for-each-ref` track, §6).
///
/// The upstream name is what the source printed: `origin/main` from status, `refs/remotes/origin/main` from refs.
enum UpstreamStatus: Sendable, Hashable {
    /// No upstream is configured.
    case none
    /// Upstream exists; counts are relative to the last fetch.
    case tracking(upstream: String, ahead: Int, behind: Int)
    /// An upstream is configured but its remote-tracking ref no longer exists.
    case gone(upstream: String)

    var upstreamName: String? {
        switch self {
        case .none: nil
        case .tracking(let name, _, _), .gone(let name): name
        }
    }

    var ahead: Int {
        if case .tracking(_, let ahead, _) = self { return ahead }
        return 0
    }

    var behind: Int {
        if case .tracking(_, _, let behind) = self { return behind }
        return 0
    }
}
