import Foundation

/// The text S-05's `Copy Report` puts on the clipboard (#110, security-review.md T11, SEC-T11-06).
///
/// Someone pastes it into an issue or a chat, so it holds only what helps review the protections: key names, the
/// verdict of each SECURITY row, and how other settings are handled, plus fixed facts (main or linked worktree, the
/// inspection time, git and Overgrove versions). It never holds configuration values, remote URLs, hosts, file system
/// paths, branch names, or error text (which can quote any of those). Subsections that can be a URL or a path
/// (`credential.<url>.helper`, `includeif.<condition>.path`) are replaced, not masked, and the finished text is
/// masked, escaped, and has the home folder shortened as a last guard.
enum SecurityReport {
    /// What `Copy Report` needs; the text is built only when the button is pressed (security review of #110).
    struct Source: Equatable {
        let inspection: WorktreeInspection
        let isMainWorktree: Bool
        let appVersion: String?
        var home = NSHomeDirectory()
        /// The repository is marked untrusted (#107).
        var isUntrusted = false
    }

    static let footer = "Values, paths, and remote URLs are not included. Credentials are masked."
    /// Details listed per row; the rest are counted.
    static let maximumDetails = 50

    static func text(_ source: Source) -> String {
        text(
            isMainWorktree: source.isMainWorktree, inspection: source.inspection, appVersion: source.appVersion,
            home: source.home, isUntrusted: source.isUntrusted)
    }

    /// - Parameter isMainWorktree: Named as `main worktree` or `linked worktree`; the branch name is free text a
    ///   repository or its owner chose, so it is not copied.
    static func text(
        isMainWorktree: Bool, inspection: WorktreeInspection, appVersion: String?, home: String = NSHomeDirectory(),
        isUntrusted: Bool = false
    ) -> String {
        // Full remote URLs never matter here: the report names remotes only.
        let model = WorktreeSecurityModel(inspection, showsFullRemoteURLs: false, isUntrusted: isUntrusted)
        var lines = ["Overgrove security report", "Worktree: \(isMainWorktree ? "main worktree" : "linked worktree")"]
        var inspected = ["Inspected: \(timestamp(model.inspectedAt))", "local and worktree scopes"]
        if let version = model.gitVersion { inspected.append(version) }
        lines.append(inspected.joined(separator: " · "))
        if let appVersion { lines.append("Overgrove: \(appVersion)") }
        // #107: the mode and how many remotes are on this Mac, never their names, paths, or URLs.
        lines.append("Untrusted: \(model.isUntrusted ? "yes" : "no")")
        lines.append("Remotes on this Mac: \(model.localRemotes.count)")

        var notes: [String] = []
        if let reason = model.blockingReason { notes.append("Queries stopped: \(reason)") }
        // The failure text can quote a path or git's stderr, so only the fact is copied.
        if model.failure != nil { notes.append("Configuration not read for this worktree.") }
        if let reason = model.fetchBlockingReason { notes.append("Fetch disabled: \(reason)") }
        if let note = model.limitNote { notes.append("Report shortened: \(note)") }
        if !notes.isEmpty { lines += [""] + notes }

        lines += ["", "Protections"]
        lines += model.rows.map(line)
        if !model.others.isEmpty {
            lines += ["", "Other repository settings"]
            lines += model.others.prefix(maximumDetails).map { finding in
                "- \(finding.reportKey): \(finding.handling)" + (finding.threat.map { " (\($0))" } ?? "")
            }
            if model.others.count > maximumDetails { lines.append("- +\(model.others.count - maximumDetails) more") }
        }
        lines += ["", footer]
        return lines.map { guarded($0, home: home) }.joined(separator: "\n")
    }

    private static func line(_ row: WorktreeSecurityModel.Row) -> String {
        let details = listed(row.reportDetails)
        switch row.mark {
        case .applied:
            return "✓ \(row.title)"
        case .neutralized:
            // As on screen: ⚠ means the repository sets something here and Overgrove works around it.
            return "⚠ \(row.title)" + (details.isEmpty ? "" : ": \(details)")
        case .unknown:
            return "✕ \(row.title) (not confirmed)" + (details.isEmpty ? "" : ": \(details)")
        }
    }

    private static func listed(_ details: [String]) -> String {
        var shown = Array(details.prefix(maximumDetails))
        if details.count > maximumDetails { shown.append("+\(details.count - maximumDetails) more") }
        return shown.joined(separator: ", ")
    }

    /// ISO 8601 in UTC: the reader's time zone is not the copier's business, and the copier's is not the reader's.
    private static func timestamp(_ date: Date) -> String {
        iso.string(from: date)
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// The last guard on every line: credentials masked, control and bidi characters escaped, home shortened to `~`.
    static func guarded(_ line: String, home: String) -> String {
        var text = CredentialMasker.mask(line)
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        if home.count > 1 { text = text.replacingOccurrences(of: home, with: "~") }
        return PathValidator.displayable(text)
    }

    // MARK: Parts

    /// `filter.lfs.process`, `remote.origin.uploadpack`, `credential.<url>.helper`, `includeif.<condition>.path`.
    /// Section and variable names are git's own; a subsection is kept only when it is a plain name, because it can
    /// be a URL (`http`, `credential`, `url`), a condition with a path (`includeif`), or anything a repository wrote.
    static func keyName(_ entry: ConfigEntry) -> String {
        let section = isPlainKey(entry.section) ? entry.section : "<section>"
        let variable = isPlainKey(entry.variable) ? entry.variable : "<key>"
        var parts = [section]
        if let subsection = entry.subsection {
            parts.append(subsectionName(subsection, section: entry.section))
        }
        parts.append(variable)
        let key = parts.joined(separator: ".")
        return entry.scope == .worktree ? "\(key) (worktree)" : key
    }

    private static func subsectionName(_ subsection: String, section: String) -> String {
        switch section {
        case "http", "credential", "url": "<url>"
        case "includeif": "<condition>"
        default: isPlainName(subsection) ? subsection : "<name>"
        }
    }

    /// `hooks/pre-commit`, `+3 more`, and the link note stay; a file name that is not a plain name becomes
    /// `hooks/<file>`.
    static func hookLines(_ lines: [String]) -> [String] {
        lines.map { line in
            guard line.hasPrefix("hooks/") else { return line }
            return isPlainName(String(line.dropFirst("hooks/".count))) ? line : "hooks/<file>"
        }
    }

    /// Remotes whose URL holds credentials, by name only: `origin (credentials in URL)`.
    static func remotesWithCredentials(_ inspection: RepoConfigInspection) -> [String] {
        inspection.remotes.filter { $0.displayURL != $0.url }.map {
            "\(isPlainName($0.name.value) ? $0.name.value : "<remote>") (credentials in URL)"
        }
    }

    /// Starts with a letter; then letters, digits, `_`, `-`; at most 64. No `.`, so a host (`git.internal.corp`) or
    /// an address (`10.0.0.7`) used as a remote or driver name is not copied, and no `/`, `:`, `@`, or spaces.
    static func isPlainName(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first, text.unicodeScalars.count <= 64, isLetter(first) else {
            return false
        }
        return text.unicodeScalars.allSatisfy { isAlphanumeric($0) || $0 == "_" || $0 == "-" }
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    /// Git lowercases section and variable names and allows letters, digits, and `-`.
    private static func isPlainKey(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.count <= 64
            && text.unicodeScalars.allSatisfy { isAlphanumeric($0) || $0 == "-" }
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }
}
