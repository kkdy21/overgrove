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
        return ComparisonModel(session: comparison, workingState: state, isListStale: isComparisonStale)
    }

    /// The worktree list failed to load while S-11 is open (#374): it stays shown, dimmed, and runs nothing new until
    /// a load succeeds (interaction.md §4.1). `‹ Graph` still closes it.
    var isComparisonStale: Bool {
        guard comparison != nil, case .failed = worktreeList else { return false }
        return true
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
        comparison = ComparisonSession(worktree: path, base: comparisonBases[path])
        runComparison()
    }

    /// Back to the graph (`‹ Graph`, `⎋`).
    func closeComparison() {
        comparisonTask?.cancel()
        comparisonPatchTask?.cancel()
        comparisonTask = nil
        comparisonPatchTask = nil
        comparisonGeneration += 1
        comparison = nil
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

    private func runComparison() {
        guard let session = comparison, !isComparisonStale, let repository else { return }
        comparisonTask?.cancel()
        comparisonPatchTask?.cancel()
        comparisonGeneration += 1
        let generation = comparisonGeneration
        comparison?.result = .loading
        comparison?.selectedFile = nil
        comparison?.patch = nil
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
            self.comparison?.bases = bases.all
            switch result {
            case .success(let comparison):
                self.comparison?.base = comparison.base
                if case .loaded(let state) = self.entry(at: session.worktree)?.state {
                    self.comparison?.workingState = state
                }
                self.comparison?.result = .loaded(comparison)
            case .failure(let error):
                self.comparison?.base = base
                self.comparison?.result = .failed(error)
            }
        }
    }

    /// Picks a file in S-11: committed (and uncommitted) changes come from the comparison patch, untracked files from
    /// the same preview as S-02.
    func selectComparisonFile(_ file: ComparisonFile) {
        guard let session = comparison, !isComparisonStale, case .loaded(let result) = session.result, let repository,
            // Untracked selections come only from the listed untracked files, and tracked ones from FILES CHANGED.
            let row = (file.isUntracked ? comparisonModel?.untracked : comparisonModel?.files)?
                .first(where: { $0.path == file.path }),
            row.isSelectable, let entry = entry(at: session.worktree)
        else { return }
        comparisonPatchTask?.cancel()
        comparison?.selectedFile = file
        comparison?.patch = .loading
        let generation = comparisonGeneration
        let loader = comparisonLoader
        let diffLoader = diffLoader
        let target = repository.repository
        let label =
            file.isUntracked
            ? "Untracked" : (row.hasUncommittedChanges ? "Committed + uncommitted" : "Committed")
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
    }
}
