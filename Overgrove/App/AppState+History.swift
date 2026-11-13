import Foundation

/// S-09 file history (#70): opened from a file's `Show History` in S-02, S-03, S-04, or S-10; it covers the graph,
/// a row shows its commit in S-03, and ⏎ or a double click opens that commit's diff of the file in S-10.
extension AppState {
    /// Opens `path`'s history as seen from `worktree` (the focused worktree when `nil`). A path that is not valid
    /// UTF-8 has no history view (its menu item is disabled).
    func showHistory(of path: GitPath, in worktree: GitPath? = nil) {
        guard path.isRepresentable, let repository, case .loaded(let listing) = worktreeList else { return }
        let wanted = worktree ?? focusedWorktreePath
        guard
            let entry = listing.entries.first(where: { $0.worktree.path == wanted })
                ?? listing.entries.first(where: { !$0.worktree.isBare })
        else { return }
        let head: ObjectID? =
            if case .loaded(let state) = entry.state { state.headCommit ?? entry.worktree.head } else {
                entry.worktree.head
            }
        closeComparison()
        clearSelectedFile()
        history.open(
            FileHistoryTarget(repository: repository.repository, worktree: entry.worktree, head: head, path: path))
    }

    /// `‹ Graph` or ⎋ in S-09.
    func closeHistory() {
        history.close()
    }

    /// A history row: its commit in S-03. The S-10 diff of a previous row closes, so the history shows again.
    func selectHistoryEntry(_ entry: FileHistoryEntry) {
        guard let repository else { return }
        clearSelectedFile()
        history.select(entry.id)
        // A commit the graph has not loaded leaves no other row highlighted (#311).
        graph.select(graph.index(of: entry.id) != nil ? entry.id : nil)
        setCommitSelection(entry.id)
        commitDetail.show(entry.commit, in: repository.repository)
    }

    /// ⏎ or a double click: that commit's diff of the file (its path in that commit) in S-10. ⎋ there returns here.
    /// The history knows a rename but not an add or a delete, so S-10's kind otherwise comes from the patch (#659).
    func openHistoryDiff(_ entry: FileHistoryEntry) {
        selectHistoryEntry(entry)
        commitDetail.selectFile(
            FileStat(
                path: entry.path, originalPath: entry.originalPath,
                status: entry.originalPath.map { _ in .renamed(score: nil) }, added: entry.added,
                deleted: entry.deleted))
    }

    /// The file S-10 shows, for its `Show History`: a WIP file in its worktree, or a commit's or stash's file in the
    /// focused worktree.
    var shownFileHistoryTarget: (path: GitPath, worktree: GitPath?)? {
        if let file = selectedFile { return (file.path, file.worktree) }
        if let file = commitDetail.selectedFile, selectedCommitOID != nil { return (file.path, nil) }
        if let file = selectedStashFile { return (file.path, nil) }
        return nil
    }

    func showHistoryOfShownFile() {
        guard let target = shownFileHistoryTarget else { return }
        showHistory(of: target.path, in: target.worktree)
    }
}
