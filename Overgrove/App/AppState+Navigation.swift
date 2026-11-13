import Foundation

/// A panel `⌘1`–`⌘4` moves keyboard focus to (interaction.md §1.2).
enum PanelFocus: Hashable, Sendable {
    case sidebar
    case center
    case detail
    case issues
}

/// One focus request; a new token makes repeating the same shortcut focus again.
struct PanelFocusRequest: Equatable, Sendable {
    let panel: PanelFocus
    let token = UUID()
}

/// Keyboard navigation and copy commands (interaction.md §3, #73). Look and copy only: nothing here writes to a
/// repository.
extension AppState {
    /// `⌘J`: selects the focused worktree's HEAD commit and scrolls the graph to it.
    var canJumpToHead: Bool { graph.head.flatMap(graph.index(of:)) != nil }

    func jumpToHead() {
        guard let head = graph.head, graph.index(of: head) != nil else { return }
        // The graph shows again, as for a search match (#311).
        history.close()
        selectCommit(head)
        graph.scroll(to: head)
    }

    /// `⌘I`: switches the worktree segment between `Changes` and `Worktree`.
    var canToggleWorktreeInfo: Bool { focusedWorktreePath != nil }

    func toggleWorktreeInfo() {
        if case .worktreeInfo = selection {
            showChanges()
        } else if let path = focusedWorktreePath {
            if selection?.worktreePath == nil { selectWorktree(path) }
            showWorktreeDetail()
        }
    }

    func focus(_ panel: PanelFocus) {
        panelFocusRequest = PanelFocusRequest(panel: panel)
    }

    /// `⌥⌘C`: the absolute path of the picked file, or of the focused worktree (Finder's Copy as Pathname).
    var fullPathToCopy: String? {
        if let file = selectedFile { return fullPath(of: file.path, in: file.worktree) }
        if let file = commitDetail.selectedFile, selectedCommitOID != nil { return fullPath(of: file.path, in: nil) }
        if let file = selectedStashFile, selectedStashOID != nil { return fullPath(of: file.path, in: nil) }
        return focusedWorktreePath?.display
    }

    /// `⎋`, the window's only Escape handler (interaction.md §3.1). ① A screen covering the graph closes, the topmost
    /// one in the order the center draws them (S-11, S-12, S-10, S-09), as its `‹ Graph` button does, and the main
    /// selection stays (#633). ② Otherwise the search clears. ③ Otherwise the main selection returns to the focused
    /// worktree's changes.
    ///
    /// The screens' `‹ Graph` buttons have no `⎋` shortcut of their own: with one, the same key press closed the screen
    /// there and then reached this handler with nothing covering the graph, which moved the selection to the WIP (#633).
    func escape() {
        if comparison != nil {
            closeComparison()
        } else if commitComparison != nil {
            closeCommitComparison()
        } else if diffViewer != nil {
            clearSelectedFile()
        } else if history.isOpen {
            closeHistory()
        } else if !searchText.isEmpty {
            searchText = ""
        } else if case .worktreeInfo = selection {
            // S-05 back to Changes (§3.1 ③); `selectWorktree` keeps the segment on purpose (#311).
            showChanges()
        } else if let path = focusedWorktreePath, selection != .wip(path) {
            selectFocusedWip()
        }
    }

    /// The graph's WIP row (`⌘↑`, `⎋`): the focused worktree's changes.
    func selectFocusedWip() {
        guard let path = focusedWorktreePath else { return }
        graph.select(nil)
        selectWorktree(path)
    }

    /// `⌘C` without a text selection (interaction.md §3.1): the SHA, the file path in the repository, the stash ref,
    /// or the issue URL, as the selection has it.
    var selectionCopyText: String? {
        if let file = selectedFile { return file.path.display }
        if let oid = selectedCommitOID {
            return commitDetail.selectedFile?.path.display ?? oid.hex
        }
        if let oid = selectedStashOID {
            return selectedStashFile?.path.display ?? stashes.first { $0.oid == oid }?.refName
        }
        if let number = selectedIssueNumber {
            return issueListModel.rows.first { $0.id == number }?.urlText
        }
        return nil
    }
}
