import AppKit
import Foundation

/// What row menus and shortcuts may do (interaction.md §5, #73): look and copy only. Nothing here runs git, writes to
/// a repository, or opens a repository file with an app (`.command`, `.app`, and scripts would run).
protocol RowActionPerforming: Sendable {
    func copy(_ text: String)
    /// Shows the item in Finder without opening it.
    func reveal(_ url: URL)
    /// Opens a Terminal window in `folder` (a folder URL handed to Terminal.app; no shell string is built).
    func openTerminal(at folder: URL)
    /// Opens an `https` page in the default browser.
    func openInBrowser(_ url: URL)
}

/// Why a reveal or open was refused.
enum RowActionRefusal: Error, Equatable {
    /// The real location is outside the repository or worktree (T14).
    case outsideRepository
    case missing
    case notHTTPS

    var message: String {
        switch self {
        case .outsideRepository: "This path points outside the repository."
        case .missing: "This file no longer exists."
        case .notHTTPS: "Only https links are opened."
        }
    }
}

enum RowActions {
    /// The real location of `file` when it lies inside `root` (interaction.md §5, security-review.md T14): a link or
    /// `..` that leads outside is refused, so Reveal in Finder never shows a place the repository chose.
    static func revealTarget(_ file: URL, within root: URL) -> Result<URL, RowActionRefusal> {
        switch PathValidator.containment(of: file, in: root) {
        case .inside(let resolved): .success(resolved)
        case .outside: .failure(.outsideRepository)
        case .missing: .failure(.missing)
        }
    }

    /// What goes on the clipboard: the text as it is shown, with control, format (bidi), and line-separator
    /// characters escaped (`\u{A}`), so a file name cannot paste a line break or a bidi override into a terminal
    /// (T14). A commit message keeps its line feeds and tabs.
    static func clipboardText(_ text: String, keepsLineBreaks: Bool = false) -> String {
        guard keepsLineBreaks else { return PathValidator.displayable(text) }
        var result = ""
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\t" {
                result.unicodeScalars.append(scalar)
            } else {
                result += PathValidator.displayable(String(scalar))
            }
        }
        return result
    }

    /// `url` when it is an `https` URL with a host; anything else (including `http`, `file`, custom schemes) is refused.
    static func browserTarget(_ url: URL) -> Result<URL, RowActionRefusal> {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
            return .failure(.notHTTPS)
        }
        return .success(url)
    }
}

/// The app's actions: the general pasteboard and `NSWorkspace`.
struct LiveRowActions: RowActionPerforming {
    static let shared = LiveRowActions()

    func copy(_ text: String) {
        // Copying to the clipboard is not a repository write (ADR-0011).
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func reveal(_ url: URL) {
        MainActor.assumeIsolated { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func openTerminal(at folder: URL) {
        MainActor.assumeIsolated {
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
            else { return }
            NSWorkspace.shared.open(
                [folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func openInBrowser(_ url: URL) {
        guard case .success(let checked) = RowActions.browserTarget(url) else { return }
        MainActor.assumeIsolated { _ = NSWorkspace.shared.open(checked) }
    }
}
