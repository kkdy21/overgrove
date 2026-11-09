import Foundation
import UniformTypeIdentifiers

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

    /// Extensions whose system preview renders web content, which may load remote resources, or names a location:
    /// previewing such a file from an untrusted repository could reach a server the repository chose. Not previewed
    /// (security review of #399; measured on macOS 26 for #468: `.xht` and `.xhtm` preview as XHTML, `.svg` as HTML,
    /// mail messages render their HTML part, internet shortcuts name a URL).
    static let webContentExtensions: Set<String> = [
        "html", "htm", "shtml", "shtm", "xhtml", "xht", "xhtm", "svg", "svgz", "webarchive", "mht", "mhtml", "webloc",
        "inetloc", "eml", "emlx", "url",
    ]

    /// The same kinds by type (#468): a file whose extension maps to a type conforming to one of these is refused too,
    /// so an extension another app declares as HTML, or a new alias of these types, is covered without listing it.
    static let refusedTypes: [UTType] = [
        .html, .svg, .webArchive, .internetLocation, .emailMessage,
        UTType("public.xhtml"), UTType("org.ietf.mhtml"), UTType("com.microsoft.internet-shortcut"),
    ].compactMap { $0 }

    /// Whether `url`'s extension, or any type that extension maps to, is one Overgrove does not preview. Every type
    /// declaring the extension is checked, not only the preferred one, since installed apps can change which one
    /// Launch Services prefers.
    static func isWebContent(_ url: URL) -> Bool {
        let pathExtension = url.pathExtension.lowercased()
        guard !pathExtension.isEmpty else { return false }
        return webContentExtensions.contains(pathExtension)
            || UTType.types(tag: pathExtension, tagClass: .filenameExtension, conformingTo: nil).contains {
                isWebContent(type: $0)
            }
    }

    static func isWebContent(type: UTType?) -> Bool {
        guard let type else { return false }
        return refusedTypes.contains { type.conforms(to: $0) }
    }

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
        // Both the name in the repository and the real file's, and the type the system reports for the file, decide
        // which preview extension draws it.
        let reported = (try? real.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        guard !isWebContent(real), !isWebContent(worktree.appendingPathComponent(relative)),
            !isWebContent(type: reported)
        else {
            return .failure(.webContent)
        }
        guard Int64(info.st_size) <= maximumSize else { return .failure(.tooLarge) }
        // The real path: a folder above swapped for a link after this check cannot redirect the panel.
        return .success(real)
    }
}
