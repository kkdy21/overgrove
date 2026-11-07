import Foundation
import Security

/// When a git chosen in Settings may run (ADR-0019, #106, T10). Checked when it is chosen and on every discovery.
///
/// Only file-system facts are read (`realpath`, `stat`, `access`, and a static code-signature check); no process runs.
/// The version is checked afterwards by `GitEnvironment.probe`.
enum GitExecutablePolicy {
    enum Outcome: Equatable {
        /// The `/usr/bin/git` shim: use the default git (ADR-0008: ~8 ms per call and the install dialog).
        case useDefault
        /// Run `resolved`, the real file behind `entered`.
        case chosen(entered: String, resolved: URL)
    }

    enum Rejection: Error, Equatable {
        case notAbsolute
        case notFound
        case notAFile
        case notExecutable
        /// Inside a registered repository, its git directory, or a worktree.
        case insideRepository
        /// Owned by someone other than root or the user (the path is the file or directory at fault).
        case unsafeOwner(String)
        /// Writable by group or others, including shared sticky directories such as `/tmp`.
        case writableByOthers(String)

        /// One line for Settings and the setup assistant. Paths are escaped for display.
        var message: String {
            switch self {
            case .notAbsolute: "The path must be absolute."
            case .notFound: "No file exists at that path."
            case .notAFile: "The path is not a file."
            case .notExecutable: "The file is not executable."
            case .insideRepository: "A git inside a registered repository cannot be used."
            case .unsafeOwner(let path):
                "\(PathValidator.displayable(path)) is owned by another user. It must belong to you or root."
            case .writableByOthers(let path):
                "Other users can change \(PathValidator.displayable(path)). Only you, root, or administrators may write to it."
            }
        }
    }

    /// The parts of `stat` the rules read. Settable so tests can stand in owners they cannot create.
    struct FileStatus: Equatable {
        var owner: uid_t
        var group: gid_t
        var mode: mode_t

        var isRegularFile: Bool { mode & S_IFMT == S_IFREG }

        /// Writable by an account that is neither root nor the owner. Group write counts unless the group is `wheel`
        /// (0) or `admin` (80), whose members can become root anyway: macOS ships `/Applications` as `root:admin`
        /// 0775, and Homebrew's `Cellar` is `<user>:admin` 0775 (ADR-0019 §2). Write by others always counts, sticky
        /// or not (`/tmp`).
        var isWritableByOthers: Bool {
            if mode & S_IWOTH != 0 { return true }
            return mode & S_IWGRP != 0 && !GitExecutablePolicy.administrativeGroups.contains(group)
        }

        /// `stat` (links followed). `nil` when the path does not exist or cannot be read.
        static func current(_ path: String) -> FileStatus? {
            var info = Darwin.stat()
            guard stat(path, &info) == 0 else { return nil }
            return FileStatus(owner: info.st_uid, group: info.st_gid, mode: info.st_mode)
        }
    }

    static let shimPath = "/usr/bin/git"
    /// `wheel` and `admin`: groups whose write access is as trusted as root's.
    static let administrativeGroups: Set<gid_t> = [0, 80]

    /// Applies ADR-0019 §1–2 to `path`.
    ///
    /// - Parameters:
    ///   - protectedDirectories: Registered repositories' top-level and common git directories and known worktrees,
    ///     as registered at the time of the check.
    ///   - currentUser: The uid allowed besides root.
    static func check(
        path: String,
        protectedDirectories: [URL],
        currentUser: uid_t = getuid(),
        fileStatus: (String) -> FileStatus? = FileStatus.current
    ) throws -> Outcome {
        guard path.hasPrefix("/") else { throw Rejection.notAbsolute }
        guard let real = realPath(path) else { throw Rejection.notFound }
        if real == shimPath { return .useDefault }
        guard let status = fileStatus(real) else { throw Rejection.notFound }
        guard status.isRegularFile else { throw Rejection.notAFile }
        guard access(real, X_OK) == 0 else { throw Rejection.notExecutable }

        // Inside a repository: the real file, or the entered path's own directory (a link kept inside a repository
        // that points elsewhere still lets the repository choose what runs).
        let enteredDirectory = realPath((path as NSString).deletingLastPathComponent)
        let candidates = [real, enteredDirectory].compactMap { $0 }
        for directory in protectedDirectories {
            let protected = realPath(directory.path) ?? directory.standardizedFileURL.path
            if candidates.contains(where: { isInside($0, protected) }) { throw Rejection.insideRepository }
        }

        // Ownership and permissions: the real file, its directories, and the directories on the entered path (a link
        // in a directory others may write could be swapped).
        var checked = Set<String>()
        for item in [real] + ancestors(of: real) + enteredAncestors(of: path) where checked.insert(item).inserted {
            guard let status = item == real ? status : fileStatus(item) else { throw Rejection.notFound }
            guard status.owner == 0 || status.owner == currentUser else { throw Rejection.unsafeOwner(item) }
            guard !status.isWritableByOthers else { throw Rejection.writableByOthers(item) }
        }
        return .chosen(entered: path, resolved: URL(fileURLWithPath: real))
    }

    /// The directories a chosen git may not be inside (ADR-0019 §1): each registered repository's top-level and common
    /// git directories, and its linked worktrees read from `<common dir>/worktrees/*/gitdir` without running git.
    /// Those files are repository-controlled, but they can only add directories, so they can only refuse more.
    static func protectedDirectories(for repositories: [RegisteredRepository]) -> [URL] {
        var directories: [URL] = []
        for repository in repositories where repository.isWellFormed {
            if let root = repository.rootPath { directories.append(URL(fileURLWithPath: root, isDirectory: true)) }
            let common = URL(fileURLWithPath: repository.commonDirectoryPath, isDirectory: true)
            directories.append(common)
            let entries = common.appendingPathComponent("worktrees", isDirectory: true)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: entries.path)) ?? []
            for name in names.prefix(maximumWorktrees) {
                let file = entries.appendingPathComponent(name).appendingPathComponent("gitdir")
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let gitFile = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard gitFile.hasPrefix("/"), !PathValidator.containsControlCharacters(gitFile) else { continue }
                directories.append(
                    URL(fileURLWithPath: (gitFile as NSString).deletingLastPathComponent, isDirectory: true))
            }
        }
        return directories
    }

    /// Linked worktrees read per repository; more are ignored (they could only refuse more paths).
    static let maximumWorktrees = 1_000

    /// Whether `path` resolves to the `/usr/bin/git` shim, which stands for the default git.
    static func isShim(_ path: String) -> Bool {
        path.hasPrefix("/") && realPath(path) == shimPath
    }

    /// Whether the file is signed by Apple (`anchor apple`). Shown in Settings only; never required (ADR-0019 §2).
    static func isAppleSigned(_ executable: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code else {
            return false
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
            let requirement
        else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    // MARK: Private

    private static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func isInside(_ path: String, _ directory: String) -> Bool {
        path == directory || path.hasPrefix(directory.hasSuffix("/") ? directory : directory + "/")
    }

    /// The real directories from `path`'s parent up to `/`.
    private static func ancestors(of path: String) -> [String] {
        var result: [String] = []
        var current = (path as NSString).deletingLastPathComponent
        while !current.isEmpty {
            result.append(current)
            if current == "/" { break }
            current = (current as NSString).deletingLastPathComponent
        }
        return result
    }

    /// The real path of every directory named on the entered path, from its parent up to `/`.
    private static func enteredAncestors(of path: String) -> [String] {
        ancestors(of: URL(fileURLWithPath: path).standardizedFileURL.path).compactMap { realPath($0) }
    }
}
