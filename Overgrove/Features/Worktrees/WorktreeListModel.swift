import Foundation

/// One row of the sidebar's WORKTREES section (information-architecture.md §4.3–§4.4, art-direction.md §6).
struct WorktreeRow: Identifiable, Equatable {
    /// Right-hand badges, in priority order: the first is drawn at the trailing edge and hidden last.
    enum Badge: Equatable {
        case conflicts(Int)
        case prunable
        case changed(Int)
        case ahead(Int)
        case behind(Int)
        case locked

        /// The SF Symbol drawn before the count (iconography.md §5.2); `nil` for ahead and behind, whose arrow is
        /// part of `text`. Colour is never the only cue (interaction.md §6.2).
        var symbol: String? {
            switch self {
            case .conflicts: "exclamationmark.triangle.fill"
            case .prunable: "questionmark.folder"
            case .changed: "pencil"
            case .locked: "lock.fill"
            case .ahead, .behind: nil
            }
        }

        /// The count, capped at `999+`; ahead and behind carry their direction (`↑2`, `↓3`).
        var text: String? {
            switch self {
            case .conflicts(let count), .changed(let count): WorktreeListModel.badgeText(count)
            case .ahead(let count): "↑" + WorktreeListModel.badgeText(count)
            case .behind(let count): "↓" + WorktreeListModel.badgeText(count)
            case .prunable, .locked: nil
            }
        }
    }

    let id: GitPath
    /// Branch name, `detached @ a1b2c3d`, or the last known name of a missing worktree. Escaped for display.
    let title: String
    let isMain: Bool
    /// Second line: `~/dev/api` for the main worktree, the folder name when it differs from the branch, or a state
    /// such as `path missing`.
    let subtitle: String?
    /// The second line is a warning (`status.prunable` colour): missing folder, refused or failed query.
    let isSubtitleWarning: Bool
    /// Missing worktrees are dimmed (§4.4).
    let isDimmed: Bool
    /// Detached and missing worktrees get a neutral tile instead of the lane colour (art-direction.md §6).
    let hasNeutralTile: Bool
    let isFocused: Bool
    let badges: [Badge]
    /// The issue its branch names (`feat/12-x`, #82): the lowest-priority badge, drawn leftmost (§4.3).
    var issueNumber: Int?
    /// Tooltip: full path, the change breakdown, upstream, lock reason, and anything the badges leave out.
    let help: String
    /// VoiceOver reads every badge, shown or not (interaction.md §6.1).
    let accessibilityLabel: String
    /// The checked-out branch's short name, escaped, for Copy Branch Name (#73); `nil` when detached or unborn.
    var branchName: String?
    /// The lane colour of the branch tip in the graph (`color.graph.lane.<n>`, #255): the tile is tinted with it.
    /// `nil` while the tip is not in a loaded page, and for neutral tiles.
    var laneIndex: Int?
}

/// The WORKTREES section built from a load. Pure, so it is unit tested without views.
struct WorktreeListModel: Equatable {
    private(set) var rows: [WorktreeRow]
    /// A non-blocking note when a parser dropped or skipped something (parsing-spec.md §1.5, §1.6).
    let warning: String?

    /// Badges above this are shown as `999+` (§4.3).
    static let badgeLimit = 999

    /// The rows whose name, folder, or path contains the sidebar filter (#74).
    func filtered(_ query: String?) -> WorktreeListModel {
        guard query != nil else { return self }
        var copy = self
        copy.rows = rows.filter { SidebarFilter.matches(query, $0.title, $0.subtitle, $0.branchName) }
        return copy
    }

    /// - Parameters:
    ///   - focused: The focused worktree's path; `nil` focuses the main worktree.
    ///   - home: Replaced by `~` in displayed paths.
    ///   - laneIndex: The graph's lane colour for a commit, when it is loaded (`GraphStore.laneIndex(of:)`).
    init(
        listing: WorktreeListing, focused: GitPath?, home: String = NSHomeDirectory(),
        laneIndex: (ObjectID) -> Int? = { _ in nil }
    ) {
        // Two records with the same path would give two rows one identity; keep the first.
        var seen = Set<GitPath>()
        let visible = listing.entries.filter { !$0.worktree.isBare && seen.insert($0.worktree.path).inserted }
        let focusedPath = Self.focusedPath(in: listing, requested: focused)
        rows = Self.sorted(visible).map { entry in
            var row = Self.row(entry, isFocused: entry.worktree.path == focusedPath, home: home)
            // Only a checked-out branch has a lane of its own (art-direction.md §6): detached and missing stay neutral.
            if !row.hasNeutralTile, entry.worktree.branch != nil, let head = entry.worktree.head {
                row.laneIndex = laneIndex(head)
            }
            return row
        }
        warning = Self.warning(for: listing)
    }

    /// The focused worktree: `requested` when it is listed, else the main worktree, else the first one.
    static func focusedPath(in listing: WorktreeListing, requested: GitPath?) -> GitPath? {
        let visible = listing.entries.filter { !$0.worktree.isBare }.map(\.worktree)
        if let requested, visible.contains(where: { $0.path == requested }) { return requested }
        return (visible.first { $0.isMain } ?? visible.first)?.path
    }

    /// What the toolbar chip and the status bar show (`AppState.snapshot`).
    static func snapshot(listing: WorktreeListing, focused: GitPath?) -> RepositorySnapshot {
        let visible = listing.entries.filter { !$0.worktree.isBare }
        let path = focusedPath(in: listing, requested: focused)
        return RepositorySnapshot(
            focusedWorktree: visible.first { $0.worktree.path == path }.map(focusedWorktree),
            worktreeCount: visible.count,
            prunableCount: visible.filter { $0.worktree.isPrunable }.count)
    }

    // MARK: Order

    /// §4.2: main first; then by branch name, detached by folder name; prunable and missing last.
    private static func sorted(_ entries: [WorktreeListing.Entry]) -> [WorktreeListing.Entry] {
        func group(_ entry: WorktreeListing.Entry) -> Int {
            if entry.worktree.isMain { return 0 }
            return isMissing(entry) ? 2 : 1
        }
        func key(_ entry: WorktreeListing.Entry) -> String {
            entry.worktree.isDetached ? folderName(entry.worktree) : (entry.worktree.branchShortName ?? "")
        }
        return entries.sorted { lhs, rhs in
            if group(lhs) != group(rhs) { return group(lhs) < group(rhs) }
            let order = key(lhs).localizedStandardCompare(key(rhs))
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.worktree.path.display < rhs.worktree.path.display
        }
    }

    private static func isMissing(_ entry: WorktreeListing.Entry) -> Bool {
        entry.worktree.isPrunable || entry.state == .missing
    }

    // MARK: Row

    private static func row(_ entry: WorktreeListing.Entry, isFocused: Bool, home: String) -> WorktreeRow {
        let worktree = entry.worktree
        let title = PathValidator.displayable(title(worktree))
        let folder = PathValidator.displayable(folderName(worktree))
        let path = PathValidator.displayable(abbreviated(worktree.path.display, home: home))
        let missing = isMissing(entry)
        let state: WorkingState? = if case .loaded(let state) = entry.state { state } else { nil }
        let (note, noteHelp) = note(for: entry)

        let subtitle: String?
        if missing {
            subtitle = "path missing"
        } else if let note {
            subtitle = note
        } else if worktree.isMain {
            subtitle = path
        } else {
            subtitle = folder == title ? nil : folder
        }

        let badges = badges(worktree: worktree, state: state)
        let issueNumber = worktree.branch.flatMap(IssueRefExtractor.issueNumber(inBranch:))
        return WorktreeRow(
            id: worktree.path,
            title: title,
            isMain: worktree.isMain,
            subtitle: subtitle,
            isSubtitleWarning: missing || note != nil,
            isDimmed: missing,
            hasNeutralTile: worktree.isDetached || missing,
            isFocused: isFocused,
            badges: badges,
            issueNumber: issueNumber,
            help: help(worktree: worktree, path: path, state: state, note: noteHelp),
            accessibilityLabel: accessibilityLabel(
                title: title, worktree: worktree, isFocused: isFocused, missing: missing, note: note, state: state)
                + (issueNumber.map { ", issue \($0)" } ?? ""),
            branchName: worktree.branchShortName.map(PathValidator.displayable))
    }

    /// §4.4. Detached comes from `worktree list` (no `branch` attribute), not from the status header.
    private static func title(_ worktree: Worktree) -> String {
        if let branch = worktree.branchShortName { return branch }
        if worktree.isDetached || worktree.head != nil {
            return "detached @ \(worktree.head?.short ?? "unknown")"
        }
        return folderName(worktree)
    }

    private static func folderName(_ worktree: Worktree) -> String {
        (worktree.path.display as NSString).lastPathComponent
    }

    private static func abbreviated(_ path: String, home: String) -> String {
        let prefix = home.hasSuffix("/") ? home : home + "/"
        if path == home { return "~" }
        return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
    }

    /// A second line for a worktree whose status is not shown, and the longer text for its tooltip.
    private static func note(for entry: WorktreeListing.Entry) -> (String?, String?) {
        switch entry.state {
        case .loaded, .missing:
            return (nil, nil)
        case .failed(let error):
            return ("Status unavailable", PathValidator.displayable(error.message))
        case .notQueried(.foreignRepository):
            return (
                "Not part of this repository",
                "This worktree entry points at a folder that belongs to another repository, so Overgrove does not "
                    + "query it."
            )
        case .notQueried(.inspectionBlocked(let reason)):
            return ("Blocked for safety", PathValidator.displayable(reason))
        case .notQueried(.unrepresentablePath):
            return ("Path cannot be read", "The path is not valid UTF-8, so Overgrove cannot pass it to git.")
        case .notQueried(.duplicate):
            return (
                "Same folder as another entry",
                "Another worktree entry leads to this folder, so its status is shown there."
            )
        case .notQueried(.limit):
            return (
                "Not loaded",
                "This repository lists more than \(RepositoryService.defaultMaximumQueriedWorktrees) worktrees. "
                    + "Overgrove loads the status of the first \(RepositoryService.defaultMaximumQueriedWorktrees)."
            )
        case .notQueried(.bare):
            return (nil, nil)
        }
    }

    private static func badges(worktree: Worktree, state: WorkingState?) -> [WorktreeRow.Badge] {
        var badges: [WorktreeRow.Badge] = []
        if let state, !state.conflicted.isEmpty { badges.append(.conflicts(state.conflicted.count)) }
        if worktree.isPrunable { badges.append(.prunable) }
        if let state {
            let changed = changedCount(state)
            if changed > 0 { badges.append(.changed(changed)) }
            if state.upstream.ahead > 0 { badges.append(.ahead(state.upstream.ahead)) }
            if state.upstream.behind > 0 { badges.append(.behind(state.upstream.behind)) }
        }
        if worktree.isLocked { badges.append(.locked) }
        return badges
    }

    /// §4.3: staged + unstaged + untracked, counted by distinct path. Conflicts have their own badge.
    static func changedCount(_ state: WorkingState) -> Int {
        Set((state.staged + state.unstaged + state.untracked).map(\.path)).count
    }

    static func badgeText(_ count: Int) -> String {
        count > badgeLimit ? "\(badgeLimit)+" : "\(count)"
    }

    private static func lockReason(_ worktree: Worktree) -> String? {
        guard case .locked(let reason) = worktree.lock else { return nil }
        return reason.map(PathValidator.displayable)
    }

    private static func help(worktree: Worktree, path: String, state: WorkingState?, note: String?) -> String {
        var lines = [path]
        if let state {
            var parts = [
                "\(state.staged.count) staged", "\(state.unstaged.count) unstaged",
                "\(state.untracked.count) untracked",
            ]
            if !state.conflicted.isEmpty { parts.insert("\(state.conflicted.count) conflicted", at: 0) }
            lines.append(parts.joined(separator: " · "))
            switch state.upstream {
            case .tracking(let upstream, let ahead, let behind):
                lines.append("↑\(ahead) ↓\(behind) vs \(PathValidator.displayable(upstream))")
            case .gone(let upstream):
                lines.append("Upstream \(PathValidator.displayable(upstream)) is gone")
            case .none:
                lines.append("No upstream")
            }
        }
        if worktree.isLocked {
            lines.append(lockReason(worktree).map { "Locked: \($0)" } ?? "Locked")
        }
        if worktree.isPrunable {
            lines.append(
                "Prunable" + (worktree.prunableReason.map { ": \(PathValidator.displayable($0))" } ?? ""))
        }
        if let note { lines.append(note) }
        return lines.joined(separator: "\n")
    }

    private static func accessibilityLabel(
        title: String, worktree: Worktree, isFocused: Bool, missing: Bool, note: String?, state: WorkingState?
    ) -> String {
        var parts = [title, "worktree"]
        if worktree.isMain { parts.append("main worktree") }
        if isFocused { parts.append("focused") }
        if let state {
            if !state.conflicted.isEmpty { parts.append("\(state.conflicted.count) conflicted") }
            let changed = changedCount(state)
            if changed > 0 { parts.append("\(changed) changed") }
            if state.upstream.ahead > 0 { parts.append("\(state.upstream.ahead) ahead") }
            if state.upstream.behind > 0 { parts.append("\(state.upstream.behind) behind") }
        }
        if worktree.isLocked { parts.append(lockReason(worktree).map { "locked, \($0)" } ?? "locked") }
        if worktree.isPrunable { parts.append("prunable") }
        if missing { parts.append("path missing") } else if let note { parts.append(note) }
        return parts.joined(separator: ", ")
    }

    // MARK: Warning and snapshot

    private static func warning(for listing: WorktreeListing) -> String? {
        var notes: [String] = []
        if listing.isPartial { notes.append("Some worktrees could not be listed because git's output was too large.") }
        if listing.isQueryLimited {
            let limit = RepositoryService.defaultMaximumQueriedWorktrees
            // Same wording as the detail of a worktree past the limit (WipDetailModel).
            notes.append(
                "This repository lists more than \(limit) worktrees. Overgrove loads the changes of the first "
                    + "\(limit).")
        }
        let incomplete = listing.entries.contains {
            if case .loaded(let state) = $0.state { return state.isPartial || state.skippedRecords > 0 }
            return false
        }
        if incomplete { notes.append("Some changes could not be read, so counts may be incomplete.") }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    private static func focusedWorktree(_ entry: WorktreeListing.Entry) -> FocusedWorktree {
        let worktree = entry.worktree
        let state: WorkingState? = if case .loaded(let state) = entry.state { state } else { nil }
        let hasUpstream: Bool = if case .tracking = state?.upstream { true } else { false }
        return FocusedWorktree(
            branch: worktree.branchShortName.map(PathValidator.displayable),
            headShortSHA: (state?.headCommit ?? worktree.head)?.short,
            ahead: state?.upstream.ahead ?? 0,
            behind: state?.upstream.behind ?? 0,
            hasUpstream: hasUpstream,
            slowStatus: entry.slowStatusHint)
    }
}

// MARK: - Launch snapshot (ADR-0018, #109)

extension WorktreeListModel {
    /// The rows a relaunch draws from a `LaunchSnapshot` while the first load runs. Same order, names, and badges as
    /// a loaded list (§4.2–§4.4), from the snapshot's counts; every row says it is updating, and nothing else (issue
    /// badges, lane colours, lock reasons, notes) is guessed.
    init(snapshot: LaunchSnapshot, home: String = NSHomeDirectory()) {
        let focused = snapshot.focusedPath ?? snapshot.rows.first { $0.isMain }?.path ?? snapshot.rows.first?.path
        let ordered = snapshot.rows.sorted { lhs, rhs in
            func group(_ row: LaunchSnapshot.Row) -> Int { row.isMain ? 0 : (row.isMissing ? 2 : 1) }
            func key(_ row: LaunchSnapshot.Row) -> String {
                row.branch == nil ? (row.path as NSString).lastPathComponent : (row.branch ?? "")
            }
            if group(lhs) != group(rhs) { return group(lhs) < group(rhs) }
            let order = key(lhs).localizedStandardCompare(key(rhs))
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.path < rhs.path
        }
        rows = ordered.map { Self.row($0, isFocused: $0.path == focused, home: home) }
        warning = nil
    }

    private static func row(_ row: LaunchSnapshot.Row, isFocused: Bool, home: String) -> WorktreeRow {
        let folder = PathValidator.displayable((row.path as NSString).lastPathComponent)
        let title = PathValidator.displayable(
            row.branch ?? (row.isDetached || row.head != nil ? "detached @ \(row.head ?? "unknown")" : folder))
        let path = PathValidator.displayable(abbreviated(row.path, home: home))
        let subtitle: String? =
            if row.isMissing { "path missing" } else if row.isMain { path } else { folder == title ? nil : folder }
        var badges: [WorktreeRow.Badge] = []
        if row.hasStatus, row.conflicts > 0 { badges.append(.conflicts(row.conflicts)) }
        if row.isMissing { badges.append(.prunable) }
        if row.hasStatus {
            if row.changed > 0 { badges.append(.changed(row.changed)) }
            if row.ahead > 0 { badges.append(.ahead(row.ahead)) }
            if row.behind > 0 { badges.append(.behind(row.behind)) }
        }
        if row.isLocked { badges.append(.locked) }
        var label = [title, "worktree"]
        if row.isMain { label.append("main worktree") }
        if isFocused { label.append("focused") }
        label.append("updating")
        return WorktreeRow(
            id: GitPath(row.path), title: title, isMain: row.isMain, subtitle: subtitle,
            isSubtitleWarning: row.isMissing, isDimmed: row.isMissing, hasNeutralTile: row.isDetached || row.isMissing,
            isFocused: isFocused, badges: badges,
            help: "\(path)\nShown from the last session while Overgrove updates this repository.",
            accessibilityLabel: label.joined(separator: ", "),
            branchName: row.branch.map(PathValidator.displayable))
    }
}
