import Foundation

/// Back and Forward over the main selection (`⌘[` / `⌘]`, interaction.md §1.4, #378).
extension AppState {
    var canGoBackInSelection: Bool { selectionHistory.canGoBack }
    var canGoForwardInSelection: Bool { selectionHistory.canGoForward }

    /// Goes to the nearest earlier selection that still exists. `false` when there is none (nothing moves).
    @discardableResult
    func goBackInSelection() -> Bool {
        var history = selectionHistory
        let entry = history.goBack { self.isAvailable($0) }
        selectionHistory = history
        guard let entry else { return false }
        restore(entry)
        return true
    }

    /// Goes to the nearest later selection that still exists. `false` when there is none.
    @discardableResult
    func goForwardInSelection() -> Bool {
        var history = selectionHistory
        let entry = history.goForward { self.isAvailable($0) }
        selectionHistory = history
        guard let entry else { return false }
        restore(entry)
        return true
    }

    /// For VoiceOver after a move (interaction.md §1.4): what is selected now.
    var selectionAnnouncement: String? {
        switch selection {
        case .wip(let path):
            let name = worktreeName(path)
            return String(localized: "Changes in \(name)")
        case .worktreeInfo(let path):
            let name = worktreeName(path)
            return String(localized: "Worktree \(name)")
        case .commit(let oid):
            let short = oid.short
            guard let index = graph.index(of: oid) else { return String(localized: "Commit \(short)") }
            let subject = PathValidator.displayable(graph.commits[index].subject)
            return String(localized: "Commit \(short), \(subject)")
        case .stash(let oid):
            guard let ref = stashes.first(where: { $0.oid == oid })?.refName else { return String(localized: "Stash") }
            return String(localized: "Stash \(ref)")
        case .issue(let number): return String(localized: "Issue \(number)")
        case nil: return nil
        }
    }

    /// The entry's target still exists: a listed worktree, a commit the graph has, a listed stash or open issue.
    private func isAvailable(_ entry: SelectionHistory.Entry) -> Bool {
        switch entry.selection {
        case .wip(let path), .worktreeInfo(let path): isListed(path)
        case .commit(let oid): graph.index(of: oid) != nil
        case .stash(let oid): stashes.contains { $0.oid == oid }
        case .issue(let number): issuePanel.issues.contains { $0.number == number }
        }
    }

    private func isListed(_ path: GitPath) -> Bool {
        guard case .loaded(let listing) = worktreeList else { return false }
        return listing.entries.contains { $0.worktree.path == path }
    }

    /// Chooses the entry again, as the user would (interaction.md §1.4): back to the graph from S-09, S-10, or S-11,
    /// the focused worktree it was chosen with, then the selection itself. Not recorded again.
    private func restore(_ entry: SelectionHistory.Entry) {
        isMovingInSelectionHistory = true
        defer { isMovingInSelectionHistory = false }
        history.close()
        clearSelectedFile()
        closeComparison()
        if let focus = entry.focus, focus != focusedWorktreePath, entry.selection.worktreePath == nil, isListed(focus) {
            selectWorktree(focus)
        }
        switch entry.selection {
        case .wip(let path):
            selectWorktree(path)
            if case .worktreeInfo = selection { showChanges() }
        case .worktreeInfo(let path):
            selectWorktree(path)
            showWorktreeDetail()
        case .commit(let oid):
            selectCommit(oid)
            graph.scroll(to: oid)
        case .stash(let oid):
            selectStash(oid)
        case .issue(let number):
            selectIssue(number)
        }
    }

    private func worktreeName(_ path: GitPath) -> String {
        guard case .loaded(let listing) = worktreeList,
            let worktree = listing.entries.first(where: { $0.worktree.path == path })?.worktree
        else { return PathValidator.displayable(path.display) }
        return PathValidator.displayable(
            worktree.branchShortName ?? URL(fileURLWithPath: path.display).lastPathComponent)
    }
}
