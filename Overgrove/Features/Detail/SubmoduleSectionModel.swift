import Foundation

/// S-02's Submodules section (#108): one row per submodule with what is known about its own working tree.
struct SubmoduleSectionModel: Equatable {
    enum Tone: Equatable {
        /// Clean, or nothing to say.
        case quiet
        /// Changes inside the submodule.
        case changed
        /// Not inspected or failed: the reason is the point.
        case attention
    }

    struct Row: Equatable, Identifiable {
        let id: GitPath
        /// Escaped for display (`PathValidator.displayable`): the path comes from the repository.
        let path: String
        let badge: String
        let tone: Tone
        /// Longer text for the tooltip (the blocking reason, the error).
        let help: String?
        /// A changed gitlink that `.gitmodules` does not list.
        let isUnlisted: Bool
    }

    enum Content: Equatable {
        case checking
        case failed
        case rows([Row])
    }

    let content: Content
    /// Submodules not inspected because of the limit (or a cut `.gitmodules` listing).
    let omitted: Int
    /// `.gitmodules` was not read (not a regular file inside the worktree).
    let isGitmodulesRefused: Bool

    /// `nil` when there is nothing to show: no submodules, nothing refused, nothing pending.
    init?(_ result: SubmodulePanel.Result?) {
        switch result {
        case nil:
            return nil
        case .pending:
            (content, omitted, isGitmodulesRefused) = (.checking, 0, false)
        case .failed:
            (content, omitted, isGitmodulesRefused) = (.failed, 0, false)
        case .loaded(let listing):
            guard !listing.submodules.isEmpty || listing.omitted > 0 || listing.isGitmodulesRefused else { return nil }
            content = .rows(listing.submodules.map(Self.row))
            omitted = listing.omitted
            isGitmodulesRefused = listing.isGitmodulesRefused
        }
    }

    static func row(_ submodule: SubmoduleStatus) -> Row {
        let (badge, tone, help) = describe(submodule.state)
        return Row(
            id: submodule.path, path: PathValidator.displayable(submodule.path.display), badge: badge, tone: tone,
            help: help, isUnlisted: !submodule.isListed)
    }

    private static func describe(_ state: SubmoduleStatus.State) -> (String, Tone, String?) {
        switch state {
        case .clean:
            return ("clean", .quiet, nil)
        case .changed(let files, let untracked, let isPartial):
            var parts: [String] = []
            if files > 0 { parts.append("\(files)\(isPartial ? "+" : "") changed") }
            if untracked > 0 { parts.append("\(untracked) untracked") }
            if parts.isEmpty { parts.append("changes (list cut)") }
            return (parts.joined(separator: " · "), .changed, nil)
        case .notCheckedOut:
            return ("not checked out", .quiet, "The submodule has no checkout here (git submodule update was not run).")
        case .gitDirectoryMissing:
            return (
                "git directory missing", .quiet,
                "Its .git names a git directory that does not exist (an interrupted git submodule update or a partial "
                    + "copy), so nothing runs there."
            )
        case .notInspected(let reason):
            return ("not inspected", .attention, help(for: reason))
        case .failed(let error):
            return ("failed", .attention, PathValidator.displayable(CredentialMasker.mask(error.message)))
        }
    }

    private static func help(for reason: SubmoduleStatus.Reason) -> String {
        switch reason {
        case .invalidPath:
            "The path leaves the worktree or is not a plain relative path."
        case .symbolicLink:
            "The path goes through a symbolic link, so Overgrove does not follow it."
        case .outsideRepository:
            "Its .git leads outside this repository's modules folder, so nothing runs there."
        case .blocked(let reason):
            "Its own settings block queries: "
                + PathValidator.displayable(CredentialMasker.mask(reason.isEmpty ? "unsafe configuration" : reason))
        }
    }
}
