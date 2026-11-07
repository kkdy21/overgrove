import Foundation

/// A repository the user registered (rev-parse probe, parsing-spec.md §11.2).
struct Repository: Sendable, Hashable, Identifiable {
    /// Top-level directory of the main worktree. `nil` for a bare repository.
    let rootURL: URL?
    /// The shared git directory (`--git-common-dir`). Every worktree of the repository shares it.
    let commonGitDirectoryURL: URL
    let isBare: Bool

    var id: String { commonGitDirectoryURL.standardizedFileURL.path }

    /// The folder name, with format and separator characters escaped (`PathValidator.displayable`).
    var displayName: String {
        PathValidator.displayable((rootURL ?? commonGitDirectoryURL).lastPathComponent)
    }
}
