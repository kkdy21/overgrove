/// A parsed `git version` (parsing-spec.md §11.1).
struct GitVersion: Sendable, Hashable, Comparable {
    /// `worktree list --porcelain -z` arrived in git 2.36 (docs/README.md §2.1).
    static let minimumSupported = GitVersion(major: 2, minor: 36, patch: 0)

    let major: Int
    let minor: Int
    let patch: Int

    var isSupported: Bool { self >= Self.minimumSupported }

    static func < (lhs: GitVersion, rhs: GitVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

extension GitVersion: CustomStringConvertible {
    var description: String { "\(major).\(minor).\(patch)" }
}
