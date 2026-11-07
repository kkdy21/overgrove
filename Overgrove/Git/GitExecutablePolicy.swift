import Foundation
import Security

/// When a git chosen in Settings may run (ADR-0019, #106, T10). Checked when it is chosen and on every discovery.
///
/// Only file-system facts are read (`realpath`, `lstat`/`stat`, `readlink`, `statfs`, `access`, and a static
/// code-signature check); no process runs. The version is checked afterwards by `GitEnvironment.probe`.
///
/// One rule set covers every directory the path goes through: each directory on the entered path, on every link in
/// its chain, and above the real file. Each must be safe to trust (owner, write access), and none may be a protected
/// directory, compared by device and inode so another name for the same directory (a firmlink, a directory link)
/// does not get around it.
enum GitExecutablePolicy {
    enum Outcome: Equatable {
        /// The `/usr/bin/git` shim: use the default git (ADR-0008: ~8 ms per call and the install dialog).
        case useDefault
        /// Run `resolved`, the real file behind `entered`.
        case chosen(entered: String, resolved: URL)
    }

    enum Rejection: Error, Equatable {
        case notAbsolute
        /// `.`, `..`, or empty components, which hide the directories the path goes through.
        case unclearPath
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
            case .notAbsolute: "The path must be absolute."
            case .unclearPath: "The path must not contain “.”, “..”, or empty parts."
            case .notFound: "No file exists at that path."
            case .notAFile: "The path is not a file."
            case .notExecutable: "The file is not executable."
            case .insideRepository: "A git inside a registered repository cannot be used."
            case .unsafeOwner(let path):
                "\(PathValidator.displayable(path)) is owned by another user. It must belong to you or root."
            case .writableByOthers(let path):
                "Other users can change \(PathValidator.displayable(path)). Only you, root, or administrators may write to it."
            case .untrustedVolume:
                "The file is on a network volume or one that ignores ownership."
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
    /// Links followed before giving up (the system's own limit is 32).
    static let maximumLinks = 32

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
        guard isClear(path) else { throw Rejection.unclearPath }
        guard let real = realPath(path) else { throw Rejection.notFound }
        if real == shimPath { return .useDefault }
        guard let status = fileStatus(real) else { throw Rejection.notFound }
        guard status.isRegularFile else { throw Rejection.notAFile }
        guard access(real, X_OK) == 0 else { throw Rejection.notExecutable }
        guard let flags = volumeFlags(real), flags & UInt32(MNT_LOCAL) != 0,
            flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0
        else { throw Rejection.untrustedVolume }

        let directories = try directoriesPassedThrough(path, real: real)
        let protected = Set(protectedDirectories.compactMap { fileStatus($0.path).map(Identity.init) })
        for directory in directories {
            guard let status = fileStatus(directory) else { throw Rejection.notFound }
            if protected.contains(Identity(status)) { throw Rejection.insideRepository }
        }
        for item in [real] + directories {
            guard let status = item == real ? status : fileStatus(item) else { throw Rejection.notFound }
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

    /// No `.`, `..`, or empty components, and no trailing slash.
    private static func isClear(_ path: String) -> Bool {
        path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// The real path of every directory `path` goes through: each directory named on the entered path and on every
    /// link in its chain (a link's own directory could swap it), and every directory above the real file.
    private static func directoriesPassedThrough(_ path: String, real: String) throws -> [String] {
        var hops = [path]
        var current = path
        for _ in 0..<maximumLinks {
            guard let target = linkTarget(current) else { break }
            current = target.hasPrefix("/") ? target : (current as NSString).deletingLastPathComponent + "/" + target
            hops.append(current)
        }
        guard linkTarget(current) == nil else { throw Rejection.notFound }
        var seen = Set<String>()
        var result: [String] = []
        for directory in hops.flatMap(namedDirectories) + namedDirectories(real) {
            guard let resolved = realPath(directory) else { throw Rejection.notFound }
            if seen.insert(resolved).inserted { result.append(resolved) }
        }
        return result
    }

    /// The directories named on `path`, from `/` down to its parent, as written (links not resolved).
    private static func namedDirectories(_ path: String) -> [String] {
        var result = ["/"]
        var prefix = ""
        for component in path.split(separator: "/").dropLast() {
            prefix += "/" + component
            result.append(prefix)
        }
        return result
    }

    /// The target of `path` if it is a symbolic link.
    private static func linkTarget(_ path: String) -> String? {
        var info = Darwin.stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink(path, &buffer, Int(PATH_MAX))
        guard count > 0 else { return nil }
        return String(decoding: buffer[0..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
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
