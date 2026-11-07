import Foundation

/// WIP detail (S-02) and the diff viewer (S-10) for worktree files. Moved out of `AppState.swift` unchanged (#253).
extension AppState {
    // MARK: WIP detail (#66)

    /// S-02 for the selected worktree, `nil` unless a loaded worktree's WIP is selected.
    var wipDetailModel: WipDetailModel? {
        guard let entry = selectedWipEntry else { return nil }
        let counts: WipDetailModel.LineCounts
        if let lineCounts, case .loaded(let state) = entry.state, lineCounts.matches(entry.worktree.path, state) {
            counts = lineCounts.result
        } else {
            counts = .pending
        }
        return WipDetailModel(entry: entry, lineCounts: counts)
    }

    private var selectedWipEntry: WorktreeListing.Entry? {
        guard case .wip(let path) = selection, case .loaded(let listing) = worktreeList else { return nil }
        return listing.entries.first { $0.worktree.path == path }
    }

    /// Queries the selected worktree's line counts unless the shown status already has them (#230). Only the
    /// selected worktree is queried, and only once its status has loaded; the service answers from its cache until
    /// that status is queried again.
    /// - Parameter refresh: Ask even when the status reads the same: after a load, the service knows whether it
    ///   re-queried that status (and runs no git if not). The current counts stay shown until the answer.
    func requestLineCounts(refresh: Bool = false) {
        guard let lineCountLoader, let repository, let entry = selectedWipEntry, case .loaded(let state) = entry.state
        else { return }
        let path = entry.worktree.path
        let isSameStatus = lineCounts?.matches(path, state) ?? false
        if isSameStatus && !refresh { return }
        lineCountTask?.cancel()
        if !isSameStatus { lineCounts = LineCountRequest(path: path, state: state, result: .pending) }
        guard !state.staged.isEmpty || !state.unstaged.isEmpty else {
            lineCounts = LineCountRequest(
                path: path, state: state,
                result: .loaded(WorkingLineCounts(staged: [], unstaged: [], isPartial: false)))
            return
        }
        let loader = lineCountLoader
        let target = repository.repository
        lineCountTask = Task { [weak self] in
            let result: WipDetailModel.LineCounts
            do throws(RepositoryLoadError) {
                // `nil`: the service has no loaded status for it (e.g. evicted); show no counts rather than an error.
                guard let counts = try await loader.lineCounts(target, worktree: path) else { return }
                result = .loaded(counts)
            } catch {
                if error == .git(.cancelled) { return }
                result = .failed
            }
            self?.finishLineCounts(result, path: path, state: state)
        }
    }

    private func finishLineCounts(_ result: WipDetailModel.LineCounts, path: GitPath, state: WorkingState) {
        guard !Task.isCancelled, let lineCounts, lineCounts.matches(path, state) else { return }
        self.lineCounts?.result = result
    }

    /// Picks a file in the WIP detail. Paths git cannot take back (not UTF-8) are not selectable.
    func selectFile(_ file: FileSelection) {
        guard let row = wipDetailModel?.row(for: file), row.isSelectable else { return }
        selectedFile = file
    }

    /// Back to the graph (`⎋`, interaction.md §3).
    func clearSelectedFile() {
        selectedFile = nil
        clearStashFile()
        commitDetail.clearFile()
    }

    // MARK: Diff viewer (#232)

    /// What the center area shows for the selected file: its title, `Staged · M`, and the load state.
    var diffViewer: (title: String, source: String, state: DiffLoadState)? {
        if let commitFile = commitFileDiff { return commitFile }
        if case .stash(let oid) = selection, let file = selectedStashFile, let state = stashFileDiff,
            let stash = stashes.first(where: { $0.oid == oid })
        {
            let source = stash.refName + (file.isFromUntracked ? " · untracked" : "")
            return (PathValidator.displayable(file.path.display), source, state)
        }
        guard let file = selectedFile, let state = diffState else { return nil }
        let letter = wipDetailModel?.row(for: file)?.kindLetter
        let source = file.group.title + (letter.map { " · \($0)" } ?? "")
        let title: String
        if case .loaded(let document) = state {
            title = document.title
        } else {
            title = PathValidator.displayable(file.path.display)
        }
        return (title, source, state)
    }

    func loadDiff() {
        diffTask?.cancel()
        diffGeneration += 1
        guard let file = selectedFile, case .loaded(let listing) = worktreeList,
            let entry = listing.entries.first(where: { $0.worktree.path == file.worktree }), let repository
        else {
            diffState = nil
            diffTask = nil
            return
        }
        let generation = diffGeneration
        let row = wipDetailModel?.row(for: file)
        // Fail closed: without its row the file cannot be shown to be an ordinary file.
        let isSubmodule = row?.isSubmodule ?? true
        let source = DiffDocument.Source(label: file.group.title, kindLetter: row?.kindLetter ?? "")
        let loader = diffLoader
        let target = repository.repository
        // A different file shows a spinner, not the previous file's diff under the new name; a reload of the same
        // file keeps the old diff on screen until the new one arrives.
        if case .loaded(let document) = diffState, document.title == PathValidator.displayable(file.path.display) {
        } else {
            diffState = .loading
        }
        diffTask = Task { [weak self] in
            let result = await loader.load(file, worktree: entry.worktree, of: target, isSubmodule: isSubmodule)
            guard let self, generation == self.diffGeneration, !Task.isCancelled else { return }
            switch result {
            case .patch(let patch):
                self.diffState = .loaded(DiffDocument(listing: patch, path: file.path, source: source))
            case .unavailable(let reason):
                self.diffState = .unavailable(reason)
            }
        }
    }

    /// A finished layout change (drag released, toggle, keyboard step). Saved for the open repository; without one
    /// it stays in memory only.
    func commitPanelLayout(_ layout: PanelLayout) {
        panelLayout = layout
        if let repository {
            layoutStore.save(layout, for: repository.repository.id)
        }
    }

    /// A finished column change (divider released or double-clicked, `⋯` menu). Saved for the open repository.
    func commitGraphColumns(_ columns: GraphColumnLayout) {
        graphColumns = columns
        if let repository {
            layoutStore.save(columns, for: repository.repository.id)
        }
    }
}
