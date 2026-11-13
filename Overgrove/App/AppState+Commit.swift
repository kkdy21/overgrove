import Foundation

/// S-03 commit detail and its S-10 file diffs (#69).
extension AppState {
    /// The selected commit, `nil` unless a commit is selected.
    var selectedCommitOID: ObjectID? {
        if case .commit(let oid) = selection { return oid }
        return nil
    }

    /// Selecting a graph row (or a parent in S-03) shows that commit in the detail panel; the focused worktree stays.
    /// Only commits the graph has loaded can be selected.
    func selectCommit(_ oid: ObjectID) {
        guard let index = graph.index(of: oid), let repository else { return }
        clearSelectedFile()
        closeComparison()
        graph.select(oid)
        setCommitSelection(oid)
        commitDetail.show(graph.commits[index], in: repository.repository)
    }

    /// S-03 for the selected commit.
    var commitDetailModel: CommitDetailModel? {
        guard let oid = selectedCommitOID, let commit = commitDetail.commit, commit.oid == oid else { return nil }
        return CommitDetailModel(
            commit: commit, detail: commitDetail.detail, pills: graph.pills[oid] ?? [],
            showsAllFiles: commitDetail.showsAllFiles, issueRepository: issuePanel.repository?.referencePath)
    }

    /// The commit's lane color index, for its pills in S-03.
    var selectedCommitLane: Int {
        guard let oid = selectedCommitOID, let index = graph.index(of: oid) else { return 0 }
        return graph.rows[index].colorIndex
    }

    /// Opens a file of the selected commit in the center (S-10).
    func selectCommitFile(_ file: FileStat) {
        guard selectedCommitOID != nil else { return }
        commitDetail.selectFile(file)
    }

    func showAllCommitFiles() {
        commitDetail.showAllFiles()
    }

    /// S-10 for a commit file: `a91f3c2 · M`, or `· vs first parent` for a merge.
    var commitFileDiff: (title: String, source: String, state: DiffLoadState)? {
        guard selectedCommitOID != nil, let file = commitDetail.selectedFile, let state = commitDetail.fileDiff,
            let commit = commitDetail.commit
        else { return nil }
        // The loaded patch's kind, which a history row's file (no status, #659) only learns from the patch; until then
        // the file's own status, if it has one.
        let letter: String? =
            if case .loaded(let document) = state { document.source.kindLetter } else {
                file.status.map { String($0.code) }
            }
        let source =
            commit.oid.short + (commit.isMerge ? " · " + String(localized: "vs first parent") : "")
            + (letter.map { " · \($0)" } ?? "")
        let title: String =
            if case .loaded(let document) = state { document.title } else {
                PathValidator.displayable(file.path.display)
            }
        return (title, source, state)
    }
}
