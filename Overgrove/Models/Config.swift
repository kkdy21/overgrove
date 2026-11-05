import Foundation

/// One entry of `git config --list --show-scope -z --includes`, in original order (parsing-spec.md §9).
struct ConfigEntry: Sendable, Hashable {
    enum Scope: String, Sendable, Hashable, CaseIterable {
        case system
        case global
        case local
        case worktree
        case command
        /// Apple Git's built-in configuration file.
        case unknown

        /// Scopes whose values come from the repository and must not be trusted (ADR-0009).
        var isRepositoryControlled: Bool { self == .local || self == .worktree }
    }

    let scope: Scope
    /// Lowercased by git.
    let section: String
    /// Case preserved; may contain dots (`credential.https://example.com.helper`).
    let subsection: String?
    /// Lowercased by git.
    let variable: String
    /// `nil` for a valueless boolean key; an empty string resets multi-valued keys.
    let value: String?

    var key: String {
        if let subsection { return "\(section).\(subsection).\(variable)" }
        return "\(section).\(variable)"
    }
}

/// What `RepoConfigInspector` found in a repository's own configuration (ADR-0009, security-review.md §3.3).
struct RepoSecurityReport: Sendable, Hashable {
    enum Handling: Sendable, Hashable {
        /// Overridden for Overgrove's own git invocations.
        case neutralized
        /// Already blocked by the common safety arguments; shown for transparency.
        case reported
        /// Not blocked; the user should know.
        case warned
    }

    struct Finding: Sendable, Hashable {
        let entry: ConfigEntry
        /// Threat ID from docs/design/security-review.md, e.g. `T4`.
        let threat: String?
        let handling: Handling
    }

    let findings: [Finding]
    /// Set when a finding cannot be neutralized safely; queries must not run (fail closed).
    let blockingReason: String?

    var isBlocked: Bool { blockingReason != nil }
}

/// The result of the last `git fetch` of a repository (G5).
struct FetchRecord: Sendable, Hashable {
    let repositoryID: String
    let finishedAt: Date
    let succeeded: Bool
    /// Short, credential-masked summary for the status bar.
    let summary: String?
}
