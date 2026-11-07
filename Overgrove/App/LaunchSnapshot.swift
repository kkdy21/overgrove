import CryptoKit
import Darwin
import Foundation

/// What the sidebar's WORKTREES section needs to draw a repository right after a relaunch (ADR-0018 §1, #109, T19).
///
/// Fields are picked one by one so nothing reaches the disk by accident: worktree paths, short branch names, short
/// HEAD SHAs, counts, and state flags. Never configuration values, inspection results, remote names or URLs,
/// credentials, error text, file names inside a worktree, commit content, or upstream names (§2). It is shown only
/// while the first load runs and never used to decide anything (§5).
struct LaunchSnapshot: Codable, Equatable, Sendable {
    static let format = 1
    /// The worktrees one load queries (`RepositoryService.defaultMaximumQueriedWorktrees`, T15).
    static let maximumRows = 64
    static let maximumBytes = 256 * 1024
    static let maximumAge: TimeInterval = 7 * 86_400
    static let maximumCount = 1_000_000
    static let maximumPathLength = 1_024
    static let maximumBranchLength = 256
    /// Fingerprinted files: 4 in the common git directory, `index`, and 2 per linked worktree.
    static let maximumStamps = 5 + 2 * maximumRows

    struct Row: Codable, Equatable, Sendable {
        enum Upstream: String, Codable, Sendable {
            case tracking
            case gone
            case none
            /// The status was not loaded.
            case unknown
        }

        let path: String
        let isMain: Bool
        /// Short branch name; `nil` when detached or unborn.
        let branch: String?
        /// Short HEAD SHA.
        let head: String?
        let isDetached: Bool
        /// Prunable, or the folder is gone.
        let isMissing: Bool
        let isLocked: Bool
        /// The status loaded, so the counts mean something.
        let hasStatus: Bool
        /// Staged, unstaged, and untracked paths (`WorktreeListModel.changedCount`).
        let changed: Int
        let conflicts: Int
        let ahead: Int
        let behind: Int
        let upstream: Upstream
    }

    /// `lstat(2)` of one file, by its name relative to a git directory (or the git executable's path).
    struct FileStamp: Codable, Equatable, Sendable {
        let name: String
        let exists: Bool
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modifiedNanoseconds: Int64
        let changedNanoseconds: Int64

        static func of(_ path: String, name: String) -> FileStamp {
            var info = stat()
            guard lstat(path, &info) == 0 else {
                return FileStamp(
                    name: name, exists: false, device: 0, inode: 0, size: 0, modifiedNanoseconds: 0,
                    changedNanoseconds: 0)
            }
            return FileStamp(
                name: name, exists: true, device: Int64(info.st_dev), inode: UInt64(info.st_ino),
                size: Int64(info.st_size),
                modifiedNanoseconds: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000
                    + Int64(info.st_mtimespec.tv_nsec),
                changedNanoseconds: Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec))
        }
    }

    let format: Int
    /// `CFBundleShortVersionString (CFBundleVersion)`.
    let appVersion: String
    /// The git executable the listing came from and its `lstat`. Checking it needs no process: a new git version is a
    /// new file there (§3).
    let gitExecutable: String
    let gitExecutableStamp: FileStamp
    /// For diagnosis only: the executable's stamp above is what invalidates (no process runs at launch).
    let gitVersion: String
    let writtenAt: Date
    /// SHA-256 of `Repository.id`, the same as the file name.
    let repositoryHash: String
    let rows: [Row]
    let stashCount: Int
    let focusedPath: String?
    /// §3: the common git directory's `HEAD`, `packed-refs`, `config`, `worktrees/`, `index`, and each linked
    /// worktree's `HEAD` and `index`.
    let fingerprint: [FileStamp]

    // MARK: Building

    /// - Returns: `nil` when nothing in `listing` can be drawn from a snapshot.
    /// - Parameter fingerprint: Taken before the load that produced `listing` started, so a change during the load
    ///   makes the snapshot stale rather than current (as for the configuration inspection cache, overview.md §5).
    ///   `nil` (the repository's admin directory could not be stamped) gives no snapshot.
    init?(
        listing: WorktreeListing, focused: GitPath?, repository: Repository, appVersion: String,
        gitExecutable: URL, gitVersion: GitVersion, fingerprint: [FileStamp]?, now: Date
    ) {
        var seen = Set<GitPath>()
        let entries = listing.entries.filter {
            !$0.worktree.isBare && $0.worktree.path.isRepresentable && seen.insert($0.worktree.path).inserted
        }
        let rows = entries.prefix(Self.maximumRows).compactMap(Self.row)
        guard !rows.isEmpty, let fingerprint else { return nil }
        format = Self.format
        self.appVersion = appVersion
        self.gitExecutable = gitExecutable.path
        gitExecutableStamp = FileStamp.of(gitExecutable.path, name: gitExecutable.path)
        self.gitVersion = "\(gitVersion.major).\(gitVersion.minor).\(gitVersion.patch)"
        writtenAt = now
        repositoryHash = Self.hash(repository)
        self.rows = rows
        stashCount = min(listing.stashes.count, Self.maximumCount)
        let focusedPath = focused.map(\.display)
        self.focusedPath = rows.contains { $0.path == focusedPath } ? focusedPath : nil
        self.fingerprint = fingerprint
    }

    private static func row(_ entry: WorktreeListing.Entry) -> Row? {
        let worktree = entry.worktree
        let path = worktree.path.display
        guard isAcceptablePath(path) else { return nil }
        let branch = worktree.branchShortName.flatMap { isAcceptableText($0, limit: maximumBranchLength) ? $0 : nil }
        let state: WorkingState? = if case .loaded(let state) = entry.state { state } else { nil }
        let upstream: Row.Upstream =
            switch state?.upstream {
            case .tracking?: .tracking
            case .gone?: .gone
            case .some(.none): .none
            case nil: .unknown
            }
        let count = { (value: Int) in min(max(value, 0), maximumCount) }
        return Row(
            path: path, isMain: worktree.isMain, branch: branch, head: worktree.head?.short,
            isDetached: worktree.isDetached, isMissing: worktree.isPrunable || entry.state == .missing,
            isLocked: worktree.isLocked, hasStatus: state != nil,
            changed: count(state.map(WorktreeListModel.changedCount) ?? 0),
            conflicts: count(state?.conflicted.count ?? 0), ahead: count(state?.upstream.ahead ?? 0),
            behind: count(state?.upstream.behind ?? 0), upstream: upstream)
    }

    /// The file name and `repositoryHash`: SHA-256 of `Repository.id` (the shared git directory path), so the
    /// directory listing shows no repository paths (`PanelLayoutStore`).
    static func hash(_ repository: Repository) -> String {
        SHA256.hash(data: Data(repository.id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Entries of `worktrees/` read at most; more makes no fingerprint, so no snapshot (T15).
    static let maximumWorktreeScan = 1_024

    /// `nil` when `worktrees/` holds more than `maximumWorktreeScan` entries. A `worktrees` that is not a real
    /// directory (a link) is stamped as itself and not listed. Linked worktrees are named by their sorted position,
    /// never by their directory name, so no repository-chosen name is written (security review of #109).
    static func fingerprint(_ gitDirectory: URL) -> [FileStamp]? {
        var stamps = ["HEAD", "packed-refs", "config", "worktrees", "index"].map {
            FileStamp.of(gitDirectory.appendingPathComponent($0).path, name: $0)
        }
        let linked = gitDirectory.appendingPathComponent("worktrees", isDirectory: true)
        var info = stat()
        guard lstat(linked.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return stamps }
        guard let directory = opendir(linked.path) else { return stamps }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            guard name != ".", name != ".." else { continue }
            names.append(name)
            if names.count > maximumWorktreeScan { return nil }
        }
        for (index, name) in names.sorted().prefix(maximumRows).enumerated() {
            for file in ["HEAD", "index"] {
                let path = linked.appendingPathComponent(name).appendingPathComponent(file).path
                stamps.append(FileStamp.of(path, name: "worktrees/\(index)/\(file)"))
            }
        }
        return stamps
    }

    // MARK: Checking (§4: the file is untrusted input)

    enum Rejection: Error, Equatable {
        case unreadable
        case tooLarge
        case malformed
        case outOfRange
        case otherVersion
        case otherRepository
        case expired
        case gitChanged
        case repositoryChanged
    }

    /// Decodes `data` and checks every field against its bounds. Says nothing about whether it is still current.
    static func decode(_ data: Data) throws(Rejection) -> LaunchSnapshot {
        guard data.count <= maximumBytes else { throw .tooLarge }
        let snapshot: LaunchSnapshot
        do {
            snapshot = try JSONDecoder().decode(LaunchSnapshot.self, from: data)
        } catch {
            throw .malformed
        }
        guard snapshot.format == format else { throw .otherVersion }
        try snapshot.checkBounds()
        return snapshot
    }

    private func checkBounds() throws(Rejection) {
        let counts = [stashCount] + rows.flatMap { [$0.changed, $0.conflicts, $0.ahead, $0.behind] }
        guard !rows.isEmpty, rows.count <= Self.maximumRows, fingerprint.count <= Self.maximumStamps,
            counts.allSatisfy({ (0...Self.maximumCount).contains($0) }),
            rows.allSatisfy({ row in
                Self.isAcceptablePath(row.path)
                    && row.branch.map { Self.isAcceptableText($0, limit: Self.maximumBranchLength) } ?? true
                    && row.head.map(Self.isShortSHA) ?? true
            }),
            Set(rows.map(\.path)).count == rows.count,
            focusedPath.map({ path in rows.contains(where: { $0.path == path }) }) ?? true,
            repositoryHash.utf8.count == 64, repositoryHash.utf8.allSatisfy(Self.isLowerHex),
            Self.isAcceptableText(appVersion, limit: 64), Self.isAcceptableText(gitVersion, limit: 32),
            Self.isAcceptablePath(gitExecutable)
        else { throw .outOfRange }
    }

    /// Absolute, at most 1,024 bytes, no control characters.
    static func isAcceptablePath(_ path: String) -> Bool {
        path.hasPrefix("/") && isAcceptableText(path, limit: maximumPathLength)
    }

    static func isAcceptableText(_ text: String, limit: Int) -> Bool {
        !text.isEmpty && text.utf8.count <= limit
            && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func isShortSHA(_ text: String) -> Bool {
        (4...64).contains(text.utf8.count) && text.utf8.allSatisfy(isLowerHex)
    }

    private static func isLowerHex(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
    }
}
