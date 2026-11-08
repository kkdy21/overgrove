import Darwin
import Foundation

/// Submodule paths and git directories (#108, T14). Both come from files the repository controls (`.gitmodules`, the
/// parent's index, the submodule's `.git` file), so neither is trusted.
extension PathValidator {
    enum SubmoduleFolder: Equatable {
        /// A directory inside the worktree, reached without any symbolic link.
        case folder(URL)
        /// Nothing at that path (the submodule was never checked out, or was removed).
        case missing
        /// Absolute, empty, `.`/`..` or empty components, not UTF-8, control characters, or not a directory.
        case invalid
        /// A component of the path is a symbolic link.
        case symbolicLink
    }

    /// Where a submodule path leads, checked component by component with `lstat(2)`, so no symbolic link (pointing
    /// out of the worktree, or into another of its folders) is followed.
    static func submoduleFolder(_ path: GitPath, in worktree: URL) -> SubmoduleFolder {
        guard let relative = path.argument, !relative.isEmpty, !relative.hasPrefix("/"),
            !containsControlCharacters(relative)
        else { return .invalid }
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        let last = components.last.map(String.init) ?? ""
        let middle = components.dropLast()
        // `a/b/` (a trailing slash) is tolerated; any other empty component, `.` or `..` is not.
        let named = last.isEmpty ? Array(middle) : Array(components)
        guard !named.isEmpty, !named.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return .invalid }

        var current = worktree
        for component in named {
            current = current.appendingPathComponent(String(component), isDirectory: true)
            var info = stat()
            guard lstat(current.path, &info) == 0 else { return .missing }
            switch info.st_mode & S_IFMT {
            case S_IFLNK: return .symbolicLink
            case S_IFDIR: continue
            default: return .invalid
            }
        }
        guard case .inside(let resolved) = containment(of: current, in: worktree) else { return .invalid }
        return .folder(resolved)
    }

    /// The git directory a checked-out submodule uses, if it belongs to this repository: with a `.git` file, under
    /// `<common>/modules/` or `<worktree git directory>/modules/` (where `git submodule` puts them, for the main and
    /// for a linked worktree); with a `.git` directory, that directory inside the submodule folder. `nil` when the
    /// submodule has no `.git` (not checked out). `.outside` for anything else, such as a `.git` file naming another
    /// repository on disk.
    enum SubmoduleGitDirectory: Equatable {
        case inside(URL)
        case notCheckedOut
        case outside
    }

    static func submoduleGitDirectory(
        of folder: URL, commonDirectory: URL, worktreeGitDirectory: URL
    ) -> SubmoduleGitDirectory {
        let entry = folder.appendingPathComponent(".git")
        var info = stat()
        guard lstat(entry.path, &info) == 0 else { return .notCheckedOut }
        let type = info.st_mode & S_IFMT
        guard type == S_IFDIR || type == S_IFREG else { return .outside }  // a symbolic link, FIFO, …
        guard let gitDirectory = gitDirectory(of: folder) else { return .outside }
        if type == S_IFDIR {
            guard case .inside = containment(of: gitDirectory, in: folder) else { return .outside }
            return .inside(gitDirectory)
        }
        for root in [commonDirectory, worktreeGitDirectory] {
            guard let modules = canonical(root.appendingPathComponent("modules", isDirectory: true)) else { continue }
            if case .inside(let resolved) = containment(of: gitDirectory, in: modules), resolved.path != modules.path {
                return .inside(resolved)
            }
        }
        return .outside
    }
}
