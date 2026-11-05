import Darwin
import Foundation

/// File-system scope checks (docs/design/security-review.md T14).
///
/// Paths are compared after `realpath(3)`, which resolves every symbolic link and `..` component. Foundation's
/// `resolvingSymlinksInPath()` is avoided because it strips `/private` only when that happens to exist, which makes
/// prefix comparisons inconsistent on macOS.
enum PathValidator {
    enum Failure: Error, Equatable {
        case notAbsolute
        case doesNotExist
        case notADirectory
    }

    /// Result of checking a folder the user picked in `NSOpenPanel`.
    struct Registration: Equatable {
        let chosen: URL
        let resolved: URL

        /// The chosen path goes through a symbolic link (SEC-T14-01). Warn and register `resolved`.
        var isThroughSymlink: Bool { PathValidator.lexicallyNormalized(chosen.path) != resolved.path }
    }

    enum Containment: Equatable {
        /// The file's real location is inside the root.
        case inside(resolved: URL)
        /// The real location is outside the root (symbolic link or `..` escape). Do not read it (SEC-T14-02).
        case outside(resolved: URL)
        /// The path (or a dangling link target) does not exist.
        case missing
    }

    enum LinkedWorktreeCheck: Equatable {
        /// `.git` is a directory: this is the main worktree.
        case mainWorktree
        /// `.git` points to `<common dir>/worktrees/<name>` and that entry points back to this worktree.
        case linked(name: String)
        case missingGitFile
        case malformedGitFile
        /// `.git` points somewhere other than this repository's `worktrees/` directory.
        case pointsOutsideRepository(target: String)
        /// The administrative entry does not point back to this worktree.
        case backPointerMismatch
    }

    /// Checks a folder chosen for registration.
    static func checkRegistration(_ url: URL) throws -> Registration {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw Failure.notAbsolute }
        guard let resolved = canonical(url) else { throw Failure.doesNotExist }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw Failure.notADirectory }
        return Registration(chosen: url, resolved: resolved)
    }

    /// Where `file` really lives relative to `root`.
    static func containment(of file: URL, in root: URL) -> Containment {
        guard let realRoot = canonical(root), let realFile = canonical(file) else { return .missing }
        let rootPath = realRoot.path.hasSuffix("/") ? realRoot.path : realRoot.path + "/"
        if realFile.path == realRoot.path || realFile.path.hasPrefix(rootPath) {
            return .inside(resolved: realFile)
        }
        return .outside(resolved: realFile)
    }

    /// The link text of a symbolic link, for display instead of following it. `nil` if `url` is not a link.
    static func symlinkTarget(at url: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    /// Verifies that a worktree's `.git` entry belongs to the repository whose shared git directory is
    /// `commonGitDirectory`.
    static func checkLinkedWorktree(root: URL, commonGitDirectory: URL) -> LinkedWorktreeCheck {
        let gitEntry = root.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitEntry.path, isDirectory: &isDirectory) else {
            return .missingGitFile
        }
        if isDirectory.boolValue { return .mainWorktree }

        guard let contents = readSmallFile(gitEntry), contents.hasPrefix("gitdir: ") else { return .malformedGitFile }
        let target = String(contents.dropFirst("gitdir: ".count)).trimmingCharacters(in: .newlines)
        guard !target.isEmpty, !target.contains("\n") else { return .malformedGitFile }

        let targetURL = target.hasPrefix("/") ? URL(fileURLWithPath: target) : root.appendingPathComponent(target)
        guard let realTarget = canonical(targetURL), let realCommon = canonical(commonGitDirectory) else {
            return .pointsOutsideRepository(target: target)
        }
        let worktrees = realCommon.appendingPathComponent("worktrees").path + "/"
        guard realTarget.path.hasPrefix(worktrees) else { return .pointsOutsideRepository(target: target) }
        let name = String(realTarget.path.dropFirst(worktrees.count))
        guard !name.isEmpty, !name.contains("/") else { return .pointsOutsideRepository(target: target) }

        // <common>/worktrees/<name>/gitdir holds the absolute path of this worktree's .git file.
        guard
            let backPointer = readSmallFile(realTarget.appendingPathComponent("gitdir"))?
                .trimmingCharacters(in: .newlines),
            let realBack = canonical(URL(fileURLWithPath: backPointer)),
            let realGitEntry = canonical(gitEntry),
            realBack == realGitEntry
        else { return .backPointerMismatch }
        return .linked(name: name)
    }

    // MARK: - Helpers

    /// Removes `.` and `..` components and duplicate slashes without touching the file system.
    /// (`standardizedFileURL` and `NSString.standardizingPath` also drop `/private`, which breaks comparisons.)
    static func lexicallyNormalized(_ path: String) -> String {
        var parts: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(component)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// `realpath(3)`: absolute path with every symbolic link and `.`/`..` resolved. `nil` if it does not exist.
    static func canonical(_ url: URL) -> URL? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    /// Reads a tiny metadata file (`.git`, `gitdir`), refusing anything larger than 4 KiB.
    private static func readSmallFile(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4097), data.count <= 4096 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
