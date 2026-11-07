import Foundation

/// One file in the WIP detail (screens.md S-02).
struct WipFileRow: Identifiable, Equatable {
    /// Position in its group; rows are rebuilt from each load, so identity is per load.
    let id: Int
    let group: WorkingChangeGroup
    let path: GitPath
    /// `M`, `A`, `D`, `R`, `C`, `T`, `U`, or `?` (iconography.md §5.1).
    let kindLetter: String
    /// `modified`, `added`, … for VoiceOver and the tooltip.
    let kindName: String
    /// Leading directories with a trailing `/`, or empty. Escaped. Drawn in `text.tertiary`.
    let directory: String
    /// The file name, or `{old → new}` for a rename or copy. Escaped. Drawn in `text.primary` Medium.
    let fileName: String
    let isSubmodule: Bool
    /// False for paths that are not valid UTF-8: shown, but they cannot be passed back to git, so they cannot be
    /// selected for a diff (parsing-spec.md §1.3).
    let isSelectable: Bool
    let help: String
    let accessibilityLabel: String
}

/// One card: a status symbol, the group name, its count, and its files.
struct WipGroupModel: Identifiable, Equatable {
    let group: WorkingChangeGroup
    let rows: [WipFileRow]
    /// Every file in the group, including those over the display limit.
    let totalCount: Int
    /// `3`, or `5,000+` when the group is over the display limit.
    let countText: String
    /// `Showing first 5,000 files · 120 more` when the group is over the display limit.
    let limitNote: String?

    var id: WorkingChangeGroup { group }
}

/// The detail panel for the focused worktree's uncommitted changes (S-02). Pure, so it is unit tested without views.
struct WipDetailModel: Equatable {
    enum Content: Equatable {
        case changes([WipGroupModel])
        /// `Working tree clean`.
        case clean
        /// The worktree's folder is gone (prunable). The app does not prune.
        case missing
        /// Status could not be read; the text says why.
        case unavailable(String)
    }

    /// Branch name or `detached @ a1b2c3d`. Escaped.
    let title: String
    let worktreePath: GitPath
    /// `~/dev/api`, escaped.
    let displayPath: String
    /// The full path for Copy Path, or `nil` when copying it would not give what the screen shows: a path that is
    /// not UTF-8 (lossy), or one with control or format characters (a pasted line feed could run a shell command;
    /// security review of #66).
    let copyablePath: String?
    /// Distinct changed paths across the groups (`7 changed files`).
    let changedFileCount: Int
    let content: Content
    /// A non-blocking note when status output was cut or had unknown records (parsing-spec.md §1.5, §1.6).
    let warning: String?

    /// Untracked files shown before `Showing first … files`. Provisional: #91 settles the value from PB-5
    /// measurements (scope-mvp.md §4 "잠정 5,000개", performance-budget.md).
    static let untrackedDisplayLimit = 5_000

    init(entry: WorktreeListing.Entry, home: String = NSHomeDirectory(), untrackedLimit: Int = untrackedDisplayLimit) {
        let worktree = entry.worktree
        title = PathValidator.displayable(
            worktree.branchShortName ?? "detached @ \(worktree.head?.short ?? "unknown")")
        worktreePath = worktree.path
        displayPath = PathValidator.displayable(Self.abbreviated(worktree.path.display, home: home))
        let full = worktree.path.display
        copyablePath = worktree.path.isRepresentable && PathValidator.displayable(full) == full ? full : nil
        switch entry.state {
        case .loaded(let state):
            let groups = Self.groups(state, untrackedLimit: untrackedLimit)
            changedFileCount =
                Set((state.staged + state.unstaged + state.untracked + state.conflicted).map(\.path))
                .count
            content = groups.isEmpty ? .clean : .changes(groups)
            warning =
                state.isPartial || state.skippedRecords > 0
                ? "Some changes could not be read, so this list may be incomplete." : nil
        case .missing:
            changedFileCount = 0
            content = .missing
            warning = nil
        case .failed(let error):
            changedFileCount = 0
            content = .unavailable(PathValidator.displayable(error.message))
            warning = nil
        case .notQueried(let reason):
            changedFileCount = 0
            content = .unavailable(Self.message(for: reason))
            warning = nil
        }
    }

    /// The groups in display order, empty ones left out.
    var groups: [WipGroupModel] {
        if case .changes(let groups) = content { return groups }
        return []
    }

    /// The row a file selection points at, if it is still listed.
    func row(for selection: FileSelection) -> WipFileRow? {
        guard selection.worktree == worktreePath else { return nil }
        return groups.first { $0.group == selection.group }?.rows.first { $0.path == selection.path }
    }

    // MARK: Groups

    /// screens.md S-02: CONFLICTED → STAGED → UNSTAGED → UNTRACKED; empty groups are hidden. Files keep git's order
    /// (by path). A file changed in both index and worktree (`MM`) is in both STAGED and UNSTAGED.
    private static func groups(_ state: WorkingState, untrackedLimit: Int) -> [WipGroupModel] {
        let lists: [(WorkingChangeGroup, [FileChange])] = [
            (.conflicted, state.conflicted), (.staged, state.staged), (.unstaged, state.unstaged),
            (.untracked, state.untracked),
        ]
        return lists.compactMap { group, changes in
            guard !changes.isEmpty else { return nil }
            let limit = group == .untracked ? untrackedLimit : Int.max
            let shown = changes.prefix(limit)
            let isOver = changes.count > shown.count
            return WipGroupModel(
                group: group,
                rows: shown.enumerated().map { row($1, index: $0, group: group) },
                totalCount: changes.count,
                countText: isOver ? "\(formatted(limit))+" : formatted(changes.count),
                limitNote: isOver
                    ? "Showing first \(formatted(limit)) files · \(formatted(changes.count - limit)) more" : nil)
        }
    }

    private static func row(_ change: FileChange, index: Int, group: WorkingChangeGroup) -> WipFileRow {
        let (directory, fileName) = displayParts(change)
        let kind = kindName(change.status)
        let original = change.originalPath.map { PathValidator.displayable($0.display) }
        let path = PathValidator.displayable(change.path.display)
        let isSelectable = change.path.isRepresentable && (change.originalPath?.isRepresentable ?? true)

        var help = original.map { "\($0) → \(path)" } ?? path
        help += "\n\(group.title): \(kind)"
        if change.isSubmodule { help += " (submodule)" }
        if !isSelectable { help += "\nThis path is not valid UTF-8, so Overgrove cannot show its diff." }

        var label = "\(kind), \(original.map { "\($0) renamed to \(path)" } ?? path)"
        if change.isSubmodule { label += ", submodule" }
        label += ", \(group.title.lowercased())"

        return WipFileRow(
            id: index, group: group, path: change.path, kindLetter: String(change.status.code), kindName: kind,
            directory: directory, fileName: fileName, isSubmodule: change.isSubmodule, isSelectable: isSelectable,
            help: help, accessibilityLabel: label)
    }

    /// `internal/log/` + `logger.go`; a rename shares its common directory once: `internal/log/` +
    /// `{format.go → encoder.go}` (screens.md S-02).
    static func displayParts(_ change: FileChange) -> (directory: String, fileName: String) {
        let new = change.path.display.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let originalPath = change.originalPath else {
            let directory = new.dropLast().map { $0 + "/" }.joined()
            return (PathValidator.displayable(directory), PathValidator.displayable(new.last ?? ""))
        }
        let old = originalPath.display.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var common = 0
        while common < min(old.count, new.count) - 1, old[common] == new[common] { common += 1 }
        let directory = new.prefix(common).map { $0 + "/" }.joined()
        let from = old.dropFirst(common).joined(separator: "/")
        let to = new.dropFirst(common).joined(separator: "/")
        return (PathValidator.displayable(directory), PathValidator.displayable("{\(from) → \(to)}"))
    }

    private static func kindName(_ status: FileChange.Status) -> String {
        switch status {
        case .modified: "modified"
        case .typeChanged: "type changed"
        case .added: "added"
        case .deleted: "deleted"
        case .renamed: "renamed"
        case .copied: "copied"
        case .untracked: "untracked"
        case .conflicted(let kind): conflictName(kind)
        }
    }

    /// The seven unmerged states of `git status` (porcelain v2 `u` records).
    static func conflictName(_ kind: ConflictKind) -> String {
        switch kind {
        case .bothDeleted: "both deleted"
        case .addedByUs: "added by us"
        case .deletedByThem: "deleted by them"
        case .addedByThem: "added by them"
        case .deletedByUs: "deleted by us"
        case .bothAdded: "both added"
        case .bothModified: "both modified"
        }
    }

    private static func message(for reason: WorktreeListing.NotQueriedReason) -> String {
        switch reason {
        case .bare:
            "A bare repository has no working tree."
        case .unrepresentablePath:
            "This worktree's path is not valid UTF-8, so Overgrove cannot pass it to git."
        case .foreignRepository:
            "This worktree entry points at a folder that belongs to another repository, so Overgrove does not query it."
        case .inspectionBlocked(let reason):
            "Overgrove stopped querying this worktree for safety. \(PathValidator.displayable(reason))"
        case .duplicate:
            "Another worktree entry leads to this folder; its changes are shown under that entry."
        case .limit:
            "This repository lists more than \(RepositoryService.defaultMaximumQueriedWorktrees) worktrees. Overgrove "
                + "loads the changes of the first \(RepositoryService.defaultMaximumQueriedWorktrees)."
        }
    }

    private static func abbreviated(_ path: String, home: String) -> String {
        let prefix = home.hasSuffix("/") ? home : home + "/"
        if path == home { return "~" }
        return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
    }

    /// `5,000`: the screens use English UI text (information-architecture.md §5).
    static func formatted(_ count: Int) -> String {
        count.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }
}

extension WorkingChangeGroup {
    var title: String {
        switch self {
        case .conflicted: "Conflicted"
        case .staged: "Staged"
        case .unstaged: "Unstaged"
        case .untracked: "Untracked"
        }
    }

    /// iconography.md §5.1.
    var symbol: String {
        switch self {
        case .conflicted: "exclamationmark.triangle.fill"
        case .staged: "checkmark.circle.fill"
        case .unstaged: "pencil"
        case .untracked: "questionmark.circle"
        }
    }
}
