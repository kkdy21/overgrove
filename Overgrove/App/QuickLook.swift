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

    /// Types whose system preview renders web content, which may load remote resources: previewing such a file
    /// from an untrusted repository could reach a server the repository chose. Not previewed (security review of
    /// #399).
    static let webContentExtensions: Set<String> = [
        "html", "htm", "xhtml", "shtml", "svg", "svgz", "webarchive", "mht", "mhtml", "webloc", "inetloc",
    ]

    /// The file to preview, by its real path: a regular file itself (not a symbolic link, a FIFO, a folder, or a hard
    /// link to another place), inside the worktree (`PathValidator.worktreeFile`), not web content, and not larger
    /// than `maximumSize`.
    static func target(_ path: GitPath, in worktree: URL) -> Result<URL, RowActionRefusal> {
        guard let relative = path.argument, !relative.isEmpty, !relative.hasPrefix("/"),
            !relative.split(separator: "/").contains("..")
        else { return .failure(.outsideRepository) }
        var info = stat()
        guard lstat(worktree.appendingPathComponent(relative).path, &info) == 0 else { return .failure(.missing) }
        // One link only: a hard link inside the worktree could name a file elsewhere.
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { return .failure(.notAFile) }
        guard let file = PathValidator.worktreeFile(path, in: worktree),
            let real = PathValidator.canonical(worktree.appendingPathComponent(file.relativePath)),
            case .inside = PathValidator.containment(of: real, in: worktree)
        else { return .failure(.outsideRepository) }
        guard !webContentExtensions.contains(real.pathExtension.lowercased()) else { return .failure(.webContent) }
        guard Int64(info.st_size) <= maximumSize else { return .failure(.tooLarge) }
        // The real path: a folder above swapped for a link after this check cannot redirect the panel.
        return .success(real)
    }
}
