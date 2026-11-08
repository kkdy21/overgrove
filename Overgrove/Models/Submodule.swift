import Foundation

/// One submodule of a worktree and what is known about its own working tree (S-02, #108).
///
/// Each submodule is its own repository with its own (untrusted) configuration. Its state is read only after its
/// `.git` leads to this repository's `modules/` directory, git agrees on where it is, and its own configuration was
/// inspected (`RepositoryService.submodules`).
struct SubmoduleStatus: Sendable, Equatable, Identifiable {
    enum State: Sendable, Equatable {
        /// Nothing changed inside.
        case clean
        /// Changed files inside the submodule (staged, unstaged, conflicted) and untracked files.
        case changed(files: Int, untracked: Int, isPartial: Bool)
        /// The folder has no checkout (`git submodule update` was not run).
        case notCheckedOut
        /// Nothing ran inside; why.
        case notInspected(Reason)
        case failed(GitError)
    }

    enum Reason: Sendable, Equatable {
        /// The path is absolute, has `.`/`..` or empty components, is not valid UTF-8, or leaves the worktree.
        case invalidPath
        /// A component of the path is a symbolic link.
        case symbolicLink
        /// Its `.git` does not lead to this repository's `modules/` directory (or a `.git` folder inside it), or git
        /// sees another repository there.
        case outsideRepository
        /// Its own configuration has something that cannot be neutralized (ADR-0009).
        case blocked(reason: String)
    }

    let path: GitPath
    /// Listed in `.gitmodules`. A changed gitlink that `.gitmodules` does not list is still shown.
    let isListed: Bool
    let state: State

    var id: GitPath { path }
}

/// The submodules of one worktree.
struct SubmoduleListing: Sendable, Equatable {
    let submodules: [SubmoduleStatus]
    /// Submodules past `RepositoryService.maximumInspectedSubmodules`, or cut from `.gitmodules` by the output limit.
    let omitted: Int
    /// `.gitmodules` was not read: it is a symbolic link or not a regular file (it is still shown which changed
    /// gitlinks exist).
    let isGitmodulesRefused: Bool

    static let empty = SubmoduleListing(submodules: [], omitted: 0, isGitmodulesRefused: false)
}
