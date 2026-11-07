import Foundation

/// Why Open in Terminal asks first (interaction.md §5, security-review.md T14, #73).
///
/// The shell Terminal opens is outside Overgrove's safety arguments: a prompt tool that runs `git status` there
/// honours the repository's own `core.fsmonitor`, filters, and hooks. A worktree whose settings were checked and hold
/// nothing that runs code opens directly; anything else (not checked, blocked, or an execution finding) is confirmed.
enum TerminalGuard {
    /// Key names listed in the confirmation at most; the rest are counted.
    static let maximumListedKeys = 8

    /// Threats whose settings run code when git runs (security-review.md T1–T7).
    static let executionThreats: Set<String> = ["T1", "T2", "T3", "T4", "T5", "T6", "T7"]

    /// What the confirmation lists, or an empty array when the folder can open directly.
    /// - Parameters:
    ///   - inspection: The worktree's configuration inspection from the load; `nil` when it was not inspected,
    ///     blocked before inspection, foreign, or failed.
    ///   - hooks: Executable hook files (`LiveWorktreeInspector.hookExecutables`).
    static func reasons(inspection: RepoConfigInspection?, hooks: [String]) -> [String] {
        guard let report = inspection?.report else {
            return ["The repository’s settings could not be checked."] + hooks
        }
        var reasons: [String] = []
        if let blocked = report.blockingReason {
            reasons.append(PathValidator.displayable(CredentialMasker.mask(blocked)))
        }
        var seen = Set<String>()
        let keys = report.findings
            .filter { $0.threat.map(executionThreats.contains) ?? false }
            .map { PathValidator.displayable(CredentialMasker.mask($0.entry.key)) }
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
        "Shell prompt tools may run git in this folder with the repository’s own settings, which can run "
            + "commands:\n\n" + reasons.joined(separator: "\n")
    }
}
