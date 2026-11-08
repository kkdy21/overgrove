import Foundation

/// Why Open in Terminal asks first (interaction.md §5, security-review.md T14, #73).
///
/// The shell Terminal opens is outside Overgrove's safety arguments: a prompt tool that runs `git status` there
/// honours the repository's own `core.fsmonitor`, filters, and hooks, and a git the user types honours its pager,
/// editor, and `!` aliases. A worktree whose settings were checked and hold no finding at all opens directly; anything
/// else (not checked, blocked, any finding whatever its threat or handling, or a hook) is confirmed (#278).
enum TerminalGuard {
    static let untrustedReason = "This repository is marked untrusted."

    /// Key names listed in the confirmation at most; the rest are counted.
    static let maximumListedKeys = 8

    /// What the confirmation lists, or an empty array when the folder can open directly.
    /// - Parameters:
    ///   - inspection: The worktree's configuration inspection from the load; `nil` when it was not inspected,
    ///     blocked before inspection, foreign, or failed.
    ///   - hooks: Executable hook files (`LiveWorktreeInspector.hookExecutables`).
    ///   - isUntrusted: The repository is marked untrusted (#107): it always asks, first reason.
    static func reasons(inspection: RepoConfigInspection?, hooks: [String], isUntrusted: Bool = false) -> [String] {
        let untrusted = isUntrusted ? [untrustedReason] : []
        guard let report = inspection?.report else {
            return untrusted + ["The repository’s settings could not be checked."] + hooks
        }
        var reasons = untrusted
        if let blocked = report.blockingReason {
            reasons.append(PathValidator.displayable(CredentialMasker.mask(blocked)))
        }
        var seen = Set<String>()
        // Every finding: what the app overrides or ignores for its own commands, the shell's git still applies.
        let keys = report.findings
            .map { PathValidator.displayable(CredentialMasker.maskConfigKey($0.entry.key)) }
            .filter { seen.insert($0).inserted }
        reasons += keys.prefix(maximumListedKeys)
        let more = keys.count - min(keys.count, maximumListedKeys) + report.omittedFindings
        if more > 0 { reasons.append("+\(more) more settings") }
        return reasons + hooks
    }
}

/// An Open in Terminal waiting for the user's confirmation.
struct TerminalConfirmation: Identifiable, Equatable {
    let id = UUID()
    let folder: URL
    let reasons: [String]

    var message: String {
        "Shell prompt tools, and git commands you type, use this repository’s own settings in this folder, which "
            + "can run commands:\n\n" + reasons.joined(separator: "\n")
    }
}
