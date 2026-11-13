import Foundation

/// Compare with base (S-11). Moved out of `AppState.swift` unchanged (#253).
extension AppState {
    // MARK: Compare with base (#158)

    /// S-11's rows, `nil` without an open comparison.
    var comparisonModel: ComparisonModel? {
        guard let comparison else { return nil }
        let state: WorkingState? =
            if case .loaded(let state) = entry(at: comparison.worktree)?.state {
                state
            } else {
                isComparisonStale ? comparison.workingState : nil
            }
        return ComparisonModel(session: comparison, workingState: state, staleNotice: comparisonStaleNotice)
    }

    /// Why an open S-11 may be out of date, or `nil` when it is current (interaction.md §4.1):
    /// - the worktree list is not loaded (#374): S-11 opens only on a loaded list, so a load failed, or a retry after a
    ///   failure is still running (the list shows `.loading` then);
    /// - its worktree is listed but its status was not read on the last load (#413: past the query limit, or its
    ///   status failed). A worktree whose folder is gone or whose configuration blocks queries closes S-11 instead
    ///   (`comparisonListApplied`).
    /// While stale, S-11 stays shown, dimmed, and runs nothing new. `‹ Graph` still closes it.
    var comparisonStaleNotice: String? {
        guard let comparison else { return nil }
        guard case .loaded = worktreeList else { return ComparisonModel.listFailedNotice }
        if case .loaded = entry(at: comparison.worktree)?.state { return nil }
        return ComparisonModel.worktreeUnreadNotice
    }

    var isComparisonStale: Bool { comparisonStaleNotice != nil }

    /// A load brought a new list while S-11 is open. S-11 belongs to one worktree, so it closes when that worktree is
    /// gone from the list (removed in Terminal, #311), its folder is gone (`prunable`, #413), its path now leads to
    /// another entry's folder (`duplicate`), or it is not queried for safety (its own configuration blocks, or it
    /// belongs to another repository, #413). When its status is merely
    /// unread (past the limit, failed), S-11 goes stale like after a failed list load, and work in flight is dropped.
    func comparisonListApplied(_ listing: WorktreeListing) {
        guard let compared = comparison?.worktree else { return }
        guard let entry = listing.entries.first(where: { $0.worktree.path == compared }) else {
            return closeComparison()
        }
        switch entry.state {
        case .loaded:
            return
        // `.duplicate`: the path now leads to another entry's folder, so it is not the worktree that was compared.
        case .missing, .notQueried(.inspectionBlocked), .notQueried(.foreignRepository), .notQueried(.duplicate):
            closeComparison()
        case .failed, .notQueried:
            dropComparisonWork()
        }
    }

    /// The worktree list failed to load (#374): a comparison or patch still running was asked on the old basis, so it
    /// is dropped rather than shown as new under the stale notice. S-11 itself stays open, except after a security stop
    /// (`.blocked`, #401): that is not "could not be read", so S-11 closes and the security state shows instead.
    ///
    /// S-12 (two commits) follows the security stop too, open with S-11 or alone (#405): it closes and its file list,
    /// commits, and patch in flight are cancelled. Other failures leave S-12 as it is: it shows two commits, which a
    /// worktree list failure cannot make out of date (interaction.md §4.1).
    func comparisonListFailed(_ error: RepositoryLoadError) {
        if case .blocked = error {
            // Closes S-12 as well, whether or not S-11 is open.
            closeComparison()
            return
        }
        guard comparison != nil else { return }
        dropComparisonWork()
    }

    /// Cancels a comparison or patch asked on a basis that is no longer current, keeping S-11 open.
    private func dropComparisonWork() {
        comparisonTask?.cancel()
        comparisonPatchTask?.cancel()
        comparisonTask = nil
        comparisonPatchTask = nil
        comparisonGeneration += 1
        isComparisonRunning = false
        isComparisonRerunPending = false
        if comparison?.patch == .loading {
            comparison?.patch = nil
            comparison?.selectedFile = nil
        }
    }

    /// Whether `path` (default: the focused worktree) can be compared: its status loaded (#157 needs it).
    func canCompare(_ path: GitPath? = nil) -> Bool {
        guard let path = path ?? focusedWorktreePath, case .loaded = entry(at: path)?.state else { return false }
        return true
    }

    /// Opens S-11 for `path` (default: the focused worktree): `⌘⇧B`, the worktree row menu, S-05's button.
    func showComparison(of path: GitPath? = nil) {
        guard let path = path ?? focusedWorktreePath, canCompare(path) else { return }
        if focusedWorktreePath != path { selectWorktree(path) }
        selectedFile = nil
        // S-11 and S-12 are never open together (screens.md S-12).
        closeCommitComparison()
        comparison = ComparisonSession(worktree: path, base: comparisonBases[path])
        // S-11 covers the card and runs the same comparison (#581).
        pauseBaseSummary()
        runComparison()
    }

    /// Back to the graph (`‹ Graph`, `⎋`). Choosing anything else closes it too, and S-12 with it (#388).
    func closeComparison() {
        closeCommitComparison()
        comparisonTask?.cancel()
        comparisonPatchTask?.cancel()
        comparisonTask = nil
        comparisonPatchTask = nil
        comparisonGeneration += 1
        isComparisonRunning = false
        isComparisonRerunPending = false
        comparison = nil
        // The card shows again: S-11's comparison is in the shared cache, so this is usually free (#581).
        refreshBaseSummary()
    }

    func chooseComparisonBase(_ base: FullRefName) {
        // Only a branch the repository listed (#157 checks again).
        guard !isComparisonStale, let worktree = comparison?.worktree, comparison?.bases.contains(base) == true
        else { return }
        comparisonBases[worktree] = base
        comparison?.base = base
        runComparison()
    }

    func setIncludeUncommitted(_ include: Bool) {
        guard comparison != nil, !isComparisonStale, comparison?.includeUncommitted != include else { return }
        comparison?.includeUncommitted = include
        runComparison()
    }

    func showAllComparisonFiles() {
        comparison?.showsAllFiles = true
    }

    /// A worktree list load succeeded while S-11 is open (#412): compares again on the new basis, so a comparison
    /// dropped by a failed load does not keep spinning and a result from before a commit is not shown as current.
    /// The shown result, the picked file, and its patch stay until the new result arrives. The patch is read again
    /// only if the result changed (an untracked file's preview always), and the old one stays shown meanwhile.
    /// A comparison still running is not restarted: it would never end while files keep changing in the worktree, so
    /// one more comparison follows when it ends.
    func comparisonListSucceeded() {
        guard comparison != nil, !isComparisonStale else { return }
        if isComparisonRunning {
            isComparisonRerunPending = true
        } else {
            runComparison(keepingResult: true)
        }
    }

    /// - Parameter keepingResult: Leaves a loaded result and its picked file shown while the new one runs (#412).
    private func runComparison(keepingResult: Bool = false) {
        guard let session = comparison, !isComparisonStale, let repository else { return }
        comparisonTask?.cancel()
        comparisonPatchTask?.cancel()
        comparisonPatchTask = nil
        comparisonGeneration += 1
        isComparisonRunning = true
        isComparisonRerunPending = false
        let generation = comparisonGeneration
        let shown: WorktreeComparison?
        if keepingResult, case .loaded(let result) = session.result {
            shown = result
        } else {
            shown = nil
            comparison?.result = .loading
            comparison?.selectedFile = nil
            comparison?.patch = nil
        }
        let loader = comparisonLoader
        let target = repository.repository
        comparisonTask = Task { [weak self] in
            let bases = await loader.bases(of: target)
            let base = session.base ?? bases.preferred
            let result: Result<WorktreeComparison, ComparisonError> =
                if let base {
                    await loader.compare(
                        target, worktree: session.worktree, base: base, includeUncommitted: session.includeUncommitted)
                } else {
                    .failure(.noBaseBranch)
                }
            guard let self, generation == self.comparisonGeneration, !Task.isCancelled else { return }
            self.isComparisonRunning = false
            self.comparison?.bases = bases.all
            switch result {
            case .success(let comparison):
                self.comparison?.base = comparison.base
                if case .loaded(let state) = self.entry(at: session.worktree)?.state {
                    self.comparison?.workingState = state
                }
                self.comparison?.result = .loaded(comparison)
                if let shown { self.keepComparisonFile(after: shown, now: comparison) }
            case .failure(let error):
                self.comparison?.base = base
                self.comparison?.result = .failed(error)
                self.comparison?.selectedFile = nil
                self.comparison?.patch = nil
            }
            if self.isComparisonRerunPending { self.runComparison(keepingResult: true) }
        }
    }

    /// After comparing again with a result shown (#412): the picked file stays only if still listed. Its patch is
    /// read again, keeping the old one shown. Only a committed-only comparison that came back the same skips it: HEAD
    /// and the base tip fix its content. With uncommitted changes the same `+n −m` can hide new content.
    private func keepComparisonFile(after shown: WorktreeComparison, now current: WorktreeComparison) {
        guard let file = comparison?.selectedFile else { return }
        let hasPatch = comparison?.patch != nil && comparison?.patch != .loading
        if current == shown, !current.includesWorkingTree, hasPatch, !file.isUntracked { return }
        if !loadComparisonFile(file, keepingShown: true) {
            // No longer listed (or not selectable): let it go.
            comparisonPatchTask?.cancel()
            comparisonPatchTask = nil
            comparison?.selectedFile = nil
            comparison?.patch = nil
        }
    }

    /// Picks a file in S-11: committed (and uncommitted) changes come from the comparison patch, untracked files from
    /// the same preview as S-02.
    func selectComparisonFile(_ file: ComparisonFile) {
        loadComparisonFile(file, keepingShown: false)
    }

    /// - Parameter keepingShown: The same file again after comparing again (#412): its loaded patch stays shown until
    ///   the new one arrives, as the WIP diff does after a load.
    /// - Returns: Whether the file was picked (still listed and selectable, and S-11 not stale).
    @discardableResult
    private func loadComparisonFile(_ file: ComparisonFile, keepingShown: Bool) -> Bool {
        guard let session = comparison, !isComparisonStale, case .loaded(let result) = session.result, let repository,
            // Untracked selections come only from the listed untracked files, and tracked ones from FILES CHANGED.
            let row = (file.isUntracked ? comparisonModel?.untracked : comparisonModel?.files)?
                .first(where: { $0.path == file.path }),
            row.isSelectable, let entry = entry(at: session.worktree)
        else { return false }
        comparisonPatchTask?.cancel()
        let keepsPatch: Bool =
            keepingShown && session.selectedFile == file && session.patch != nil && session.patch != .loading
        comparison?.selectedFile = file
        if !keepsPatch { comparison?.patch = .loading }
        let generation = comparisonGeneration
        let loader = comparisonLoader
        let diffLoader = diffLoader
        let target = repository.repository
        let label =
            file.isUntracked
            ? WorkingChangeGroup.untracked.title
            : (row.hasUncommittedChanges
                ? String(localized: "Committed + uncommitted", comment: "Diff source")
                : String(localized: "Committed", comment: "Diff source"))
        let source = DiffDocument.Source(label: label, kindLetter: row.kindLetter)
        comparisonPatchTask = Task { [weak self] in
            let loaded: DiffLoadResult
            if file.isUntracked {
                loaded = await diffLoader.load(
                    FileSelection(worktree: session.worktree, group: .untracked, path: file.path),
                    worktree: entry.worktree, of: target, isSubmodule: false)
            } else {
                loaded = await loader.patch(
                    target, worktree: session.worktree, base: result.base, file: file.path,
                    originalPath: row.originalPath, includeUncommitted: result.includesWorkingTree)
            }
            guard let self, generation == self.comparisonGeneration, !Task.isCancelled,
                self.comparison?.selectedFile == file
            else { return }
            switch loaded {
            case .patch(let patch):
                self.comparison?.patch = .loaded(DiffDocument(listing: patch, path: file.path, source: source))
            case .unavailable(let reason):
                self.comparison?.patch = .unavailable(reason)
            }
        }
        return true
    }
}
