import SwiftUI

/// A sidebar section that opens and closes (interaction.md §1.2, #592).
enum SidebarSection: Hashable, Sendable, CaseIterable {
    case worktrees, local, remote, tags, stashes, issues
}

/// A sidebar row the arrow keys can move to: one that does something when clicked.
enum SidebarItem: Hashable, Sendable {
    case worktree(GitPath)
    /// A LOCAL or REMOTE branch row (full ref name) and its tip in the graph.
    case branch(id: String, tip: ObjectID)
    /// A TAGS row (full ref name) and the commit it names.
    case tag(id: String, commit: ObjectID)
    case stash(ObjectID)
    case issue(Int)

    /// The id the row carries for `ScrollViewReader`.
    var scrollID: String {
        switch self {
        // Paths are bytes: hex keeps NFC and NFD spellings apart.
        case .worktree(let path): "sidebar.worktree:" + path.raw.map { String(format: "%02x", $0) }.joined()
        case .branch(let id, _): "sidebar.branch:" + BranchNode.key(id)
        case .tag(let id, _): "sidebar.tag:" + BranchNode.key(id)
        case .stash(let oid): "sidebar.stash:" + oid.hex
        case .issue(let number): "sidebar.issue:\(number)"
        }
    }
}

/// Where the arrow keys start: the item opened last from the sidebar, or the transient anchor `⌘4` leaves just before
/// the first ISSUES row.
enum SidebarCursor: Hashable, Sendable {
    case item(SidebarItem)
    case issuesStart
}

/// The sidebar as one keyboard focus unit (interaction.md §1.2, #592): which rows `↑`/`↓` visit, where they start,
/// and where they go. Pure, so the rules are unit tested without views.
enum SidebarNavigation {
    /// What the sidebar shows, after the filter.
    struct Content {
        var worktrees: [GitPath] = []
        var local: [BranchNode] = []
        var remote: [BranchNode] = []
        var tags: [TagRow] = []
        var stashes: [ObjectID] = []
        var issues: [Int] = []
        /// Sections that are open.
        var expanded: Set<SidebarSection> = Set(SidebarSection.allCases)
        /// Open branch folders by section (LOCAL, REMOTE).
        var openFolders: [SidebarSection: Set<String>] = [:]
        /// The sidebar filter is on: every folder shows its matches, as on screen.
        var isFiltered = false
    }

    /// The app's selection, to tell where the sidebar cursor is.
    struct Selection: Equatable {
        var focusedWorktree: GitPath?
        var selectedCommit: ObjectID?
        var selectedStash: ObjectID?
        var selectedIssue: Int?
    }

    enum Position: Equatable {
        /// On `items[index]`.
        case at(Int)
        /// Between `items[index - 1]` and `items[index]` (the `⌘4` anchor).
        case before(Int)
        /// Nowhere in the visible rows: `↓` starts at the first row, `↑` at the last.
        case none
    }

    /// The rows `↑`/`↓` visit, top to bottom: worktrees, branches in open folders, tags, stashes, issues. Collapsed
    /// sections, closed folders, folder rows, and rows without a tip in the graph (a tree or blob) are skipped.
    static func items(_ content: Content) -> [SidebarItem] {
        var items: [SidebarItem] = []
        let open = content.expanded
        if open.contains(.worktrees) { items += content.worktrees.map(SidebarItem.worktree) }
        for (section, nodes) in [(SidebarSection.local, content.local), (.remote, content.remote)]
        where open.contains(section) {
            let folders = content.isFiltered ? SidebarFilter.folderIDs(nodes) : content.openFolders[section] ?? []
            for row in BranchListModel.visibleRows(nodes, open: folders) {
                if case .branch(let branch) = row.node, let tip = branch.tip {
                    items.append(.branch(id: branch.id, tip: tip))
                }
            }
        }
        if open.contains(.tags) {
            items += content.tags.compactMap { row in row.commit.map { SidebarItem.tag(id: row.id, commit: $0) } }
        }
        if open.contains(.stashes) { items += content.stashes.map(SidebarItem.stash) }
        if open.contains(.issues) { items += content.issues.map(SidebarItem.issue) }
        return items
    }

    /// `item` is what the app has selected now.
    static func isCurrent(_ item: SidebarItem, _ selection: Selection) -> Bool {
        switch item {
        case .worktree(let path): path == selection.focusedWorktree
        case .branch(_, let tip): tip == selection.selectedCommit
        case .tag(_, let commit): commit == selection.selectedCommit
        case .stash(let oid): oid == selection.selectedStash
        case .issue(let number): number == selection.selectedIssue
        }
    }

    /// Where the arrow keys start.
    ///
    /// The item opened last (`cursor`) while it is still selected; otherwise from the selection, in this order: the
    /// chosen branch or tag row (`chosenRef`) whose tip is the selected commit, the selected stash, the selected issue,
    /// the focused worktree. A worktree row is always selected, so it comes last: after a tag is clicked the cursor
    /// is the tag row. A commit chosen in the graph that no row names leaves the focused worktree row, the one the
    /// sidebar shows selected. After `⌘4` (`.issuesStart`) the selected issue, or the anchor before the first issue.
    static func position(
        in items: [SidebarItem], cursor: SidebarCursor?, chosenRef: String?, selection: Selection
    ) -> Position {
        func index(_ match: (SidebarItem) -> Bool) -> Position? { items.firstIndex(where: match).map(Position.at) }
        switch cursor {
        case .issuesStart:
            if let number = selection.selectedIssue, let found = index({ $0 == .issue(number) }) { return found }
            if let first = items.firstIndex(where: { if case .issue = $0 { true } else { false } }) {
                return .before(first)
            }
        case .item(let item) where isCurrent(item, selection):
            if let found = index({ $0 == item }) { return found }
        default:
            break
        }
        if let chosenRef, let commit = selection.selectedCommit,
            let found = index({
                switch $0 {
                case .branch(let id, let tip): id == chosenRef && tip == commit
                case .tag(let id, let target): id == chosenRef && target == commit
                default: false
                }
            })
        {
            return found
        }
        if let stash = selection.selectedStash, let found = index({ $0 == .stash(stash) }) { return found }
        if let issue = selection.selectedIssue, let found = index({ $0 == .issue(issue) }) { return found }
        if let path = selection.focusedWorktree, let found = index({ $0 == .worktree(path) }) { return found }
        return .none
    }

    /// The row `↑`/`↓` (`⌘↑`/`⌘↓` with `toEnd`) goes to from `position`, or `nil` when there is nothing to move to
    /// (no rows, or already at that end).
    static func move(in items: [SidebarItem], from position: Position, down: Bool, toEnd: Bool) -> SidebarItem? {
        guard !items.isEmpty else { return nil }
        let target: Int
        if toEnd {
            target = down ? items.count - 1 : 0
        } else {
            switch position {
            case .at(let index): target = down ? index + 1 : index - 1
            case .before(let index): target = down ? index : index - 1
            case .none: target = down ? 0 : items.count - 1
            }
        }
        guard items.indices.contains(target) else { return nil }
        if case .at(let index) = position, index == target { return nil }
        return items[target]
    }
}

/// Where each built sidebar row is, in the sidebar scroll view's coordinates (#636): the arrow keys scroll only when
/// the row they move to is not fully in view below the pinned section header. A reference type, so recording frames
/// on every scroll does not redraw the sidebar.
@MainActor
final class SidebarRowFrames {
    private(set) var frames: [String: CGRect] = [:]

    func record(_ frame: CGRect, for id: String) { frames[id] = frame }
    func forget(_ id: String) { frames[id] = nil }
}

extension EnvironmentValues {
    /// Set by `SidebarPanel` (or a test) so rows can report where they are (#636).
    @Entry var sidebarRowFrames: SidebarRowFrames?
}

extension View {
    /// Reports this sidebar row's frame under `id` (its `SidebarItem.scrollID`), for the arrow keys (#636).
    func sidebarRowFrame(_ id: String) -> some View {
        modifier(SidebarRowFrameReporter(id: id))
    }
}

private struct SidebarRowFrameReporter: ViewModifier {
    let id: String
    @Environment(\.sidebarRowFrames) private var frames

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(SidebarRowFrameSpace.name))
            } action: { frame in
                frames?.record(frame, for: id)
            }
            .onDisappear { frames?.forget(id) }
    }
}

/// The coordinate space of the sidebar's scroll view: (0, 0) is the top of the visible area.
enum SidebarRowFrameSpace {
    static let name = "sidebar.scroll"
}
