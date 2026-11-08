import Foundation

/// Which pull request belongs to which local branch (ADR-0023 §4), built once per listing or PR list.
///
/// A public repository accepts pull requests from any fork, with any head branch name, so a branch name alone never
/// links a PR. A local branch gets a PR only when all of these match:
/// - the PR's head owner and repository name equal the `OWNER/NAME` of the branch's upstream remote's github.com URL,
///   ASCII case-insensitively (GitHub ignores case; a remote URL keeps what the user typed);
/// - the PR's head branch equals the branch's upstream ref on that remote (`refs/heads/<name>`), byte for byte.
///
/// The upstream remote and ref come from `branch.<name>.remote` and `branch.<name>.merge`, never from splitting the
/// remote-tracking ref, because a remote name may contain `/`. A PR without a head repository or owner (a deleted
/// fork) links to nothing. `isCrossRepository` is not used.
struct PullRequestLinkIndex: Equatable {
    static let empty = PullRequestLinkIndex(byBranch: [:])

    /// Local branch full ref name → its pull request.
    private let byBranch: [String: PullRequest]

    private init(byBranch: [String: PullRequest]) {
        self.byBranch = byBranch
    }

    /// - Parameters:
    ///   - branches: Local and remote-tracking branches; only local ones with an upstream are linked.
    ///   - remotes: The verified listing's remote names and their github.com repositories (`GitHubRemote`); a remote
    ///     on another host is absent.
    init(pullRequests: [PullRequest], branches: [Branch], remotes: [String: GitHubRepository]) {
        guard !pullRequests.isEmpty, !remotes.isEmpty else {
            self = .empty
            return
        }
        // Keys are bytes: Swift `String` equality and hashing ignore Unicode normalization.
        var candidates: [Key: PullRequest] = [:]
        for pullRequest in pullRequests {
            guard let head = pullRequest.head else { continue }
            let key = Self.key(owner: head.owner, name: head.name, branch: Array(head.branch.utf8))
            if let current = candidates[key], !Self.isPreferred(pullRequest, over: current) { continue }
            candidates[key] = pullRequest
        }
        var byBranch: [String: PullRequest] = [:]
        let headsPrefix = Array("refs/heads/".utf8)
        for branch in branches where branch.kind == .local {
            guard let remote = branch.upstreamRemote, let repository = remotes[remote],
                let ref = branch.upstreamRemoteRef.map({ Array($0.utf8) }), ref.starts(with: headsPrefix),
                ref.count > headsPrefix.count
            else { continue }
            let key = Self.key(
                owner: repository.owner, name: repository.name, branch: Array(ref.dropFirst(headsPrefix.count)))
            if let pullRequest = candidates[key] { byBranch[branch.fullName] = pullRequest }
        }
        self.byBranch = byBranch
    }

    func pullRequest(forBranch fullName: String) -> PullRequest? {
        byBranch[fullName]
    }

    var isEmpty: Bool { byBranch.isEmpty }

    /// Open first, then the most recently updated, then the higher number (ADR-0023 §4).
    static func isPreferred(_ lhs: PullRequest, over rhs: PullRequest) -> Bool {
        if (lhs.state == .open) != (rhs.state == .open) { return lhs.state == .open }
        let (left, right) = (lhs.updatedAt ?? .distantPast, rhs.updatedAt ?? .distantPast)
        if left != right { return left > right }
        return lhs.number > rhs.number
    }

    /// `owner` and `name` with ASCII letters lowercased, and the branch bytes unchanged. Separate fields, so no
    /// byte in one part can stand in for a boundary between parts.
    private struct Key: Hashable {
        let owner: [UInt8]
        let name: [UInt8]
        let branch: [UInt8]
    }

    private static func key(owner: String, name: String, branch: [UInt8]) -> Key {
        Key(owner: asciiLowercased(owner), name: asciiLowercased(name), branch: branch)
    }

    private static func asciiLowercased(_ text: String) -> [UInt8] {
        text.utf8.map { (0x41...0x5A).contains($0) ? $0 | 0x20 : $0 }
    }
}
