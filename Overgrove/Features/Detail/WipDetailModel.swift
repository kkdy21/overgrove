import Foundation

/// Added and deleted lines of one file in the WIP detail, or a binary file (screens.md S-02, #230).
enum WipLineCount: Equatable {
    case lines(added: Int, deleted: Int)
    case binary
}

/// Added and deleted lines summed over files (a group, or the whole detail).
struct WipLineTotals: Equatable {
    let added: Int
    let deleted: Int

    /// The added share of the ratio bar, 0…1; `nil` when nothing was added or deleted.
    var addedFraction: Double? {
        let total = Double(added) + Double(deleted)
        return total > 0 ? Double(added) / total : nil
    }

    /// The sum of `totals`, or `nil` if it does not fit in `Int` (counts come from repository output).
    static func sum(_ totals: [WipLineTotals]) -> WipLineTotals? {
        var added = 0
        var deleted = 0
        for total in totals {
            let (newAdded, addedOverflow) = added.addingReportingOverflow(total.added)
            let (newDeleted, deletedOverflow) = deleted.addingReportingOverflow(total.deleted)
            guard !addedOverflow, !deletedOverflow else { return nil }
            (added, deleted) = (newAdded, newDeleted)
        }
        return WipLineTotals(added: added, deleted: deleted)
    }
}

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
    /// `nil` while counts load, for untracked, conflicted and submodule rows, and for files past a cut output.
    let lineCount: WipLineCount?
    /// False for paths that are not valid UTF-8: shown, but they cannot be passed back to git, so they cannot be
    /// selected for a diff (parsing-spec.md §1.3).
    let isSelectable: Bool
    /// The old name of a renamed file, so its diff pairs both names (#309).
    var originalPath: GitPath? = nil
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
    /// Staged and unstaged only, once every file's counts are known (screens.md S-02: untracked has no total).
    let lineTotals: WipLineTotals?

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

    /// The line counts that go with the shown status (#230): queried after the status, so they can lag behind it.
    enum LineCounts: Equatable {
        case pending
        case loaded(WorkingLineCounts)
        case failed
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
    /// Summed over the staged and unstaged groups (an `MM` file counts in both), once every count is known.
    let lineTotals: WipLineTotals?
    /// `Line counts unavailable` when the numstat query failed.
    let lineCountNote: String?

    /// Untracked files shown before `Showing first … files`. Provisional: #91 settles the value from PB-5
    /// measurements (scope-mvp.md §4 "잠정 5,000개", performance-budget.md).
    static let untrackedDisplayLimit = 5_000

    init(
        entry: WorktreeListing.Entry,
        lineCounts: LineCounts = .pending,
        home: String = NSHomeDirectory(),
        untrackedLimit: Int = untrackedDisplayLimit
    ) {
        let worktree = entry.worktree
        title = PathValidator.displayable(
            worktree.branchShortName ?? "detached @ \(worktree.head?.short ?? "unknown")")
        worktreePath = worktree.path
        displayPath = PathValidator.displayable(Self.abbreviated(worktree.path.display, home: home))
        let full = worktree.path.display
        copyablePath = worktree.path.isRepresentable && PathValidator.displayable(full) == full ? full : nil
        switch entry.state {
        case .loaded(let state):
            let groups = Self.groups(state, lineCounts: lineCounts, untrackedLimit: untrackedLimit)
            changedFileCount =
                Set((state.staged + state.unstaged + state.untracked + state.conflicted).map(\.path))
                .count
            content = groups.isEmpty ? .clean : .changes(groups)
            warning =
                state.isPartial || state.skippedRecords > 0
                ? String(localized: "Some changes could not be read, so this list may be incomplete.") : nil
            let counted = groups.filter { $0.group == .staged || $0.group == .unstaged }
            let totals = counted.compactMap(\.lineTotals)
            lineTotals = !counted.isEmpty && totals.count == counted.count ? WipLineTotals.sum(totals) : nil
            lineCountNote =
                lineCounts == .failed && !counted.isEmpty ? String(localized: "Line counts unavailable") : nil
        case .missing:
            changedFileCount = 0
            content = .missing
            warning = nil
            lineTotals = nil
            lineCountNote = nil
        case .failed(let error):
            changedFileCount = 0
            content = .unavailable(PathValidator.displayable(error.message))
            warning = nil
            lineTotals = nil
            lineCountNote = nil
        case .notQueried(let reason):
            changedFileCount = 0
            content = .unavailable(Self.message(for: reason))
            warning = nil
            lineTotals = nil
            lineCountNote = nil
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
    private static func groups(
        _ state: WorkingState, lineCounts: LineCounts, untrackedLimit: Int
    ) -> [WipGroupModel] {
        let lists: [(WorkingChangeGroup, [FileChange])] = [
            (.conflicted, state.conflicted), (.staged, state.staged), (.unstaged, state.unstaged),
            (.untracked, state.untracked),
        ]
        return lists.compactMap { group, changes in
            guard !changes.isEmpty else { return nil }
            let limit = group == .untracked ? untrackedLimit : Int.max
            let shown = changes.prefix(limit)
            let isOver = changes.count > shown.count
            let stats = Self.stats(for: group, in: lineCounts)
            let rows = shown.enumerated().map { index, change in
                row(change, index: index, group: group, lineCount: lineCount(change, stats))
            }
            return WipGroupModel(
                group: group,
                rows: rows,
                totalCount: changes.count,
                countText: isOver ? "\(formatted(limit))+" : formatted(changes.count),
                limitNote: isOver
                    ? String(
                        localized: "Showing first \(formatted(limit)) files · \(formatted(changes.count - limit)) more")
                    : nil,
                lineTotals: totals(rows, lineCounts: lineCounts, hasStats: stats != nil))
        }
    }

    // MARK: Line counts (#230)

    /// The numstat of the group's side; untracked and conflicted files have none (parsing-spec.md §8.3).
    private static func stats(for group: WorkingChangeGroup, in lineCounts: LineCounts) -> [GitPath: FileStat]? {
        guard case .loaded(let counts) = lineCounts else { return nil }
        switch group {
        case .staged: return counts.staged
        case .unstaged: return counts.unstaged
        case .conflicted, .untracked: return nil
        }
    }

    /// A submodule's numstat counts `Subproject commit` lines, not file lines, so it is not shown.
    private static func lineCount(_ change: FileChange, _ stats: [GitPath: FileStat]?) -> WipLineCount? {
        guard !change.isSubmodule, let stat = stats?[change.path] else { return nil }
        guard let added = stat.added, let deleted = stat.deleted else { return .binary }
        return .lines(added: added, deleted: deleted)
    }

    /// The group total, only when every row (submodules aside) has its count: a partial sum would read as complete.
    private static func totals(_ rows: [WipFileRow], lineCounts: LineCounts, hasStats: Bool) -> WipLineTotals? {
        guard hasStats, case .loaded(let counts) = lineCounts, !counts.isPartial else { return nil }
        var totals: [WipLineTotals] = []
        for row in rows where !row.isSubmodule {
            switch row.lineCount {
            case .lines(let added, let deleted):
                totals.append(WipLineTotals(added: added, deleted: deleted))
            case .binary:
                continue
            case nil:
                return nil  // the status lists a file the numstat did not: they were taken at different times
            }
        }
        return WipLineTotals.sum(totals)
    }

    /// `+40 −8`; a zero side is left out (`+12`, `−2`), and nothing when both are zero (screens.md S-02).
    static func lineCountText(added: Int, deleted: Int) -> (added: String?, deleted: String?) {
        (added > 0 ? "+\(formatted(added))" : nil, deleted > 0 ? "\u{2212}\(formatted(deleted))" : nil)
    }

    private static func row(
        _ change: FileChange, index: Int, group: WorkingChangeGroup, lineCount: WipLineCount?
    ) -> WipFileRow {
        let (directory, fileName) = displayParts(change)
        let kind = kindName(change.status)
        let original = change.originalPath.map { PathValidator.displayable($0.display) }
        let path = PathValidator.displayable(change.path.display)
        let isSelectable = change.path.isRepresentable && (change.originalPath?.isRepresentable ?? true)

        var help = original.map { "\($0) → \(path)" } ?? path
        help += "\n\(group.title): \(kind)"
        if change.isSubmodule { help += " (" + String(localized: "submodule") + ")" }
        if let lineCount { help += "\n\(lineCountDescription(lineCount))" }
        if !isSelectable {
            help += "\n" + String(localized: "This path is not valid UTF-8, so Overgrove cannot show its diff.")
        }

        let label = fileAccessibilityLabel(
            leading: [group.title, kind], path: path, original: original,
            extras: change.isSubmodule ? [String(localized: "submodule")] : [], lineCount: lineCount)

        return WipFileRow(
            id: index, group: group, path: change.path, kindLetter: String(change.status.code), kindName: kind,
            directory: directory, fileName: fileName, isSubmodule: change.isSubmodule, lineCount: lineCount,
            isSelectable: isSelectable, originalPath: change.originalPath,
            help: help, accessibilityLabel: label)
    }

    /// VoiceOver text for a file row (interaction.md §6.1): `Staged, modified, src/a.swift, 42 lines added, 8 removed`.
    /// The state and kind are words, a rename reads `old renamed to new`, and the first word is capitalized.
    static func fileAccessibilityLabel(
        leading: [String], path: String, original: String?, extras: [String] = [], lineCount: WipLineCount?
    ) -> String {
        var parts = leading
        parts.append(original.map { String(localized: "\($0) renamed to \(path)") } ?? path)
        parts += extras
        if let lineCount { parts.append(lineCountDescription(lineCount)) }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// The same for a file of a commit, stash, or comparison (S-03, S-04, S-11), from its numstat.
    static func fileAccessibilityLabel(_ stat: FileStat, extras: [String] = []) -> String {
        let lineCount: WipLineCount? =
            if stat.isBinary {
                .binary
            } else if let added = stat.added, let deleted = stat.deleted {
                .lines(added: added, deleted: deleted)
            } else {
                nil
            }
        return fileAccessibilityLabel(
            leading: stat.status.map { [kindName($0)] } ?? [], path: PathValidator.displayable(stat.path.display),
            original: stat.originalPath.map { PathValidator.displayable($0.display) }, extras: extras,
            lineCount: lineCount)
    }

    /// `40 lines added, 8 removed` for the tooltip and VoiceOver.
    static func lineCountDescription(_ lineCount: WipLineCount) -> String {
        switch lineCount {
        case .binary:
            return String(localized: "binary file")
        case .lines(let added, let deleted):
            let addedText = formatted(added)
            let deletedText = formatted(deleted)
            return added == 1
                ? String(localized: "\(addedText) line added, \(deletedText) removed")
                : String(localized: "\(addedText) lines added, \(deletedText) removed")
        }
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

    static func kindName(_ status: FileChange.Status) -> String {
        switch status {
        case .modified: String(localized: "modified", comment: "File change kind")
        case .typeChanged: String(localized: "type changed", comment: "File change kind")
        case .added: String(localized: "added", comment: "File change kind")
        case .deleted: String(localized: "deleted", comment: "File change kind")
        case .renamed: String(localized: "renamed", comment: "File change kind")
        case .copied: String(localized: "copied", comment: "File change kind")
        case .untracked: String(localized: "untracked", comment: "File change kind")
        case .conflicted(let kind): conflictName(kind)
        }
    }

    /// The seven unmerged states of `git status` (porcelain v2 `u` records).
    static func conflictName(_ kind: ConflictKind) -> String {
        switch kind {
        case .bothDeleted: String(localized: "both deleted", comment: "File change kind")
        case .addedByUs: String(localized: "added by us", comment: "File change kind")
        case .deletedByThem: String(localized: "deleted by them", comment: "File change kind")
        case .addedByThem: String(localized: "added by them", comment: "File change kind")
        case .deletedByUs: String(localized: "deleted by us", comment: "File change kind")
        case .bothAdded: String(localized: "both added", comment: "File change kind")
        case .bothModified: String(localized: "both modified", comment: "File change kind")
        }
    }

    private static func message(for reason: WorktreeListing.NotQueriedReason) -> String {
        switch reason {
        case .bare:
            String(localized: "A bare repository has no working tree.")
        case .unrepresentablePath:
            String(localized: "This worktree's path is not valid UTF-8, so Overgrove cannot pass it to git.")
        case .foreignRepository:
            String(
                localized:
                    "This worktree entry points at a folder that belongs to another repository, so Overgrove does not query it."
            )
        case .inspectionBlocked(let reason):
            String(
                localized:
                    "Overgrove stopped querying this worktree for safety. \(PathValidator.displayable(SafetyReason.display(reason)))"
            )
        case .duplicate:
            String(localized: "Another worktree entry leads to this folder; its changes are shown under that entry.")
        case .limit:
            String(
                localized:
                    "This repository lists more than \(RepositoryService.defaultMaximumQueriedWorktrees) worktrees. Overgrove loads the changes of the first \(RepositoryService.defaultMaximumQueriedWorktrees)."
            )
        }
    }

    private static func abbreviated(_ path: String, home: String) -> String {
        let prefix = home.hasSuffix("/") ? home : home + "/"
        if path == home { return "~" }
        return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
    }

    /// `5,000 changed files` for the WIP header (#499, #543).
    static func changedFilesText(_ count: Int) -> String {
        let number = formatted(count)
        return count == 1 ? String(localized: "\(number) changed file") : String(localized: "\(number) changed files")
    }

    /// `5,000`: the screens use English UI text (information-architecture.md §5).
    static func formatted(_ count: Int) -> String {
        count.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }
}

extension WorkingChangeGroup {
    var title: String {
        switch self {
        case .conflicted: String(localized: "Conflicted", comment: "File group")
        case .staged: String(localized: "Staged", comment: "File group")
        case .unstaged: String(localized: "Unstaged", comment: "File group")
        case .untracked: String(localized: "Untracked", comment: "File group")
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
