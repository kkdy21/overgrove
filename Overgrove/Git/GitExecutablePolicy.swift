import Foundation
import Security

/// When a git chosen in Settings may run (ADR-0019, #106, T10). Checked when it is chosen and on every discovery.
///
/// Only file-system facts are read (`realpath`, `stat`, `statfs`, `access`, and a static code-signature check); no
/// process runs. The version is checked afterwards by `GitEnvironment.probe`.
///
/// One rule covers the real file (`realpath` of the chosen path) and every directory above it: each must be safe to
/// trust (owner, write access), and none may be a protected directory, compared by device and inode so another name
/// for the same directory (a firmlink) does not get around it. Only the real file runs, and every discovery checks
/// again, so links on the way to it are not judged (ADR-0019 §1–2).
enum GitExecutablePolicy {
    enum Outcome: Equatable {
        /// The `/usr/bin/git` shim: use the default git (ADR-0008: ~8 ms per call and the install dialog).
        case useDefault
        /// Run `resolved`, the real file behind `entered`.
        case chosen(entered: String, resolved: URL)
    }

    enum Rejection: Error, Equatable {
        case notAbsolute
        /// Control characters, which could hide what the path names.
        case invalidCharacters
        case notFound
        case notAFile
        case notExecutable
        /// Inside a registered repository, its git directory, or a worktree.
        case insideRepository
        /// Owned by someone other than root or the user (the path is the file or directory at fault).
        case unsafeOwner(String)
        /// Writable by others, or by a group other than `wheel` and `admin`, including shared sticky directories.
        case writableByOthers(String)
        /// On a volume that ignores ownership or is not local, where mode bits prove nothing.
        case untrustedVolume

        /// One line for Settings and the setup assistant. Paths are escaped for display.
        var message: String {
            switch self {
            case .notAbsolute: String(localized: "The path must be absolute.")
            case .invalidCharacters: String(localized: "The path contains control characters.")
            case .notFound: String(localized: "No file exists at that path.")
            case .notAFile: String(localized: "The path is not a file.")
            case .notExecutable: String(localized: "The file is not executable.")
            case .insideRepository: String(localized: "A git inside a registered repository cannot be used.")
            case .unsafeOwner(let path):
                String(
                    localized:
                        "\(PathValidator.displayable(path)) is owned by another user. It must belong to you or root.")
            case .writableByOthers(let path):
                String(
                    localized:
                        "Other users can change \(PathValidator.displayable(path)). Only you, root, or administrators may write to it."
                )
            case .untrustedVolume:
                String(localized: "The file is on a network volume or one that ignores ownership.")
            }
        }
    }

    /// The parts of `stat` the rules read. Settable so tests can stand in owners they cannot create.
    struct FileStatus: Equatable {
        var owner: uid_t
        var group: gid_t
        var mode: mode_t
        var device: dev_t = 0
        var inode: ino_t = 0

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
            return FileStatus(
                owner: info.st_uid, group: info.st_gid, mode: info.st_mode, device: info.st_dev, inode: info.st_ino)
        }
    }

    static let shimPath = "/usr/bin/git"
    /// `wheel` and `admin`: groups whose write access is as trusted as root's.
    static let administrativeGroups: Set<gid_t> = [0, 80]

    /// `statfs` flags of the volume holding `path`; `nil` when it cannot be read.
    static func currentVolumeFlags(_ path: String) -> UInt32? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return info.f_flags
    }

    /// Applies ADR-0019 §1–2 to `path`.
    ///
    /// - Parameters:
    ///   - protectedDirectories: `protectedDirectories(for:)` of the registered repositories, read now.
    ///   - currentUser: The uid allowed besides root.
    static func check(
        path: String,
        protectedDirectories: [URL],
        currentUser: uid_t = getuid(),
        fileStatus: (String) -> FileStatus? = FileStatus.current,
        volumeFlags: (String) -> UInt32? = currentVolumeFlags
    ) throws -> Outcome {
        guard path.hasPrefix("/") else { throw Rejection.notAbsolute }
        guard !PathValidator.containsControlCharacters(path) else { throw Rejection.invalidCharacters }
        guard let real = realPath(path) else { throw Rejection.notFound }
        if real == shimPath { return .useDefault }
        guard let status = fileStatus(real) else { throw Rejection.notFound }
        guard status.isRegularFile else { throw Rejection.notAFile }
        guard access(real, X_OK) == 0 else { throw Rejection.notExecutable }
        guard let flags = volumeFlags(real), flags & UInt32(MNT_LOCAL) != 0,
            flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0
        else { throw Rejection.untrustedVolume }

        let protected = Set(protectedDirectories.compactMap { fileStatus($0.path).map(Identity.init) })
        for item in [real] + ancestors(of: real) {
            guard let status = item == real ? status : fileStatus(item) else { throw Rejection.notFound }
            if item != real, protected.contains(Identity(status)) { throw Rejection.insideRepository }
            guard status.owner == 0 || status.owner == currentUser else { throw Rejection.unsafeOwner(item) }
            guard !status.isWritableByOthers else { throw Rejection.writableByOthers(item) }
        }
        return .chosen(entered: path, resolved: URL(fileURLWithPath: real))
    }

    /// Whether `path` resolves to the `/usr/bin/git` shim, which stands for the default git.
    static func isShim(_ path: String) -> Bool {
        path.hasPrefix("/") && realPath(path) == shimPath
    }

    /// The directories a chosen git may not be inside (ADR-0019 §1): each registered repository's top-level and common
    /// git directories, and its linked worktrees read from `<common dir>/worktrees/*/gitdir` without running git.
    ///
    /// Those files are repository-controlled. Only small regular files are read, opened without following links and
    /// without blocking, so a FIFO, a link to a device, or a huge file is skipped. They can only add directories, so
    /// they can only refuse more. Called only when a git is chosen, never for the default git.
    static func protectedDirectories(for repositories: [RegisteredRepository]) -> [URL] {
        var directories: [URL] = []
        for repository in repositories where repository.isWellFormed {
            if let root = repository.rootPath { directories.append(URL(fileURLWithPath: root, isDirectory: true)) }
            let common = URL(fileURLWithPath: repository.commonDirectoryPath, isDirectory: true)
            directories.append(common)
            let entries = common.appendingPathComponent("worktrees", isDirectory: true)
            for name in directoryNames(entries.path, limit: maximumWorktrees) {
                let entry = entries.appendingPathComponent(name, isDirectory: true)
                guard isPlainDirectory(entry.path),
                    let text = readSmallFile(entry.appendingPathComponent("gitdir").path)
                else { continue }
                let written = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !written.isEmpty, !PathValidator.containsControlCharacters(written) else { continue }
                // git 2.48+ can write it relative to the entry (`worktree.useRelativePaths`).
                let gitFile = written.hasPrefix("/") ? written : entry.path + "/" + written
                let worktree = URL(fileURLWithPath: (gitFile as NSString).deletingLastPathComponent, isDirectory: true)
                    .standardizedFileURL
                // `/` would refuse every git; a repository must not be able to switch the feature off that way.
                guard worktree.path != "/" else { continue }
                directories.append(worktree)
            }
        }
        return directories
    }

    /// Linked worktrees read per repository; more are ignored (they could only refuse more paths).
    static let maximumWorktrees = 1_000
    /// A `gitdir` file holds one path.
    static let maximumGitdirBytes = 4_096

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

    /// Device and inode: the identity of a directory under any of its names.
    private struct Identity: Hashable {
        let device: dev_t
        let inode: ino_t

        init(_ status: FileStatus) {
            device = status.device
            inode = status.inode
        }
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The directories above `path` (a real path), from its parent up to `/`.
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

    private static func isPlainDirectory(_ path: String) -> Bool {
        var info = Darwin.stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// Up to `limit` entry names of a real (unlinked) directory.
    private static func directoryNames(_ path: String, limit: Int) -> [String] {
        guard isPlainDirectory(path), let stream = opendir(path) else { return [] }
        defer { closedir(stream) }
        var names: [String] = []
        var scanned = 0
        while scanned < limit + 2, let entry = readdir(stream) {
            scanned += 1
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    /// A regular file of at most `maximumGitdirBytes`, opened without following a link or blocking on a FIFO.
    private static func readSmallFile(_ path: String) -> String? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = Darwin.stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_size <= maximumGitdirBytes
        else { return nil }
        var buffer = [UInt8](repeating: 0, count: maximumGitdirBytes)
        let count = read(descriptor, &buffer, maximumGitdirBytes)
        guard count >= 0 else { return nil }
        return String(decoding: buffer[0..<count], as: UTF8.self)
    }
}
