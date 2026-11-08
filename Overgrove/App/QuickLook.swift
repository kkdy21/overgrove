import Foundation

/// Quick Look for working tree files (#399, interaction.md §5, security-review.md T14).
///
/// Quick Look hands the file to whichever preview extension claims its type, which then parses repository content.
/// From macOS 15 only sandboxed app extensions preview files; macOS 14 can still load legacy `.qlgenerator` plug-ins
/// without a sandbox. So Overgrove offers Quick Look on macOS 15 and later only (ADR-0003 keeps macOS 14 supported;
/// the action is simply absent there).
enum QuickLook {
    /// Larger files are not previewed: a preview extension would read them whole.
    static let maximumSize: Int64 = 100 * 1024 * 1024

    static func isAvailable(on version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Bool
    {
        version.majorVersion >= 15
    }

    /// The file to preview: a valid worktree file (`PathValidator.worktreeFile`) that is a regular file itself, not a
    /// symbolic link, a FIFO, or anything else, and not larger than `maximumSize`.
    static func target(_ path: GitPath, in worktree: URL) -> Result<URL, RowActionRefusal> {
        guard let file = PathValidator.worktreeFile(path, in: worktree) else { return .failure(.outsideRepository) }
        let url = worktree.appendingPathComponent(file.relativePath)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .failure(.missing) }
        guard info.st_mode & S_IFMT == S_IFREG else { return .failure(.notAFile) }
        guard Int64(info.st_size) <= maximumSize else { return .failure(.tooLarge) }
        return .success(url)
    }
}
