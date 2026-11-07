import Foundation

/// Stash list and stash detail (S-04). Moved out of `AppState.swift` unchanged (#253).
extension AppState {
    // MARK: Stashes (#71)

    /// The repository's stashes, newest first; empty until the list loads.
    var stashes: [Stash] {
        if case .loaded(let listing) = worktreeList { return listing.stashes }
        return []
    }

    var isStashListPartial: Bool {
        if case .loaded(let listing) = worktreeList { return listing.isStashListPartial }
        return false
    }

    var selectedStashOID: ObjectID? {
        if case .stash(let oid) = selection { return oid }
        return nil
    }

    /// S-04 for the selected stash, `nil` unless a stash is selected.
    var stashDetailModel: StashDetailModel? {
        guard let oid = selectedStashOID, let stash = stashes.first(where: { $0.oid == oid }) else { return nil }
        return StashDetailModel(stash: stash, state: stashDetail ?? .loading)
    }

    /// Marks a commit as the detail panel's subject (`AppState+Commit.swift`, which cannot write `selection`).
    func setCommitSelection(_ oid: ObjectID) {
        selection = .commit(oid)
    }

    /// Selecting a stash shows it in the detail panel; the focused worktree stays (information-architecture.md §2.2).
    func selectStash(_ oid: ObjectID) {
        guard stashes.contains(where: { $0.oid == oid }) else { return }
        selectedFile = nil
        closeComparison()
        graph.select(nil)
        selection = .stash(oid)
        loadStash()
    }

    func loadStash() {
        stashTask?.cancel()
        stashFileTask?.cancel()
        stashGeneration += 1
        selectedStashFile = nil
        stashFileDiff = nil
        guard let oid = selectedStashOID, let stash = stashes.first(where: { $0.oid == oid }), let repository
        else {
            stashDetail = nil
            return
        }
        stashDetail = .loading
        loadedStashOID = oid
        let generation = stashGeneration
        let loader = stashLoader
        let target = repository.repository
        let worktree = focusedWorktreePath.flatMap { entry(at: $0)?.worktree }
        stashTask = Task { [weak self] in
            let result = await loader.files(of: stash, in: target, worktree: worktree)
            guard let self, generation == self.stashGeneration, !Task.isCancelled else { return }
            switch result {
            case .files(let detail): self.stashDetail = .loaded(detail)
            case .unavailable(let reason): self.stashDetail = .unavailable(reason)
            }
        }
    }

    /// Picks a file in S-04; the center shows its patch (S-10).
    func selectStashFile(_ file: FileStat) {
        guard let oid = selectedStashOID, let stash = stashes.first(where: { $0.oid == oid }),
            case .loaded(let detail) = stashDetail, detail.files.contains(file), file.path.isRepresentable,
            let repository
        else { return }
        stashFileTask?.cancel()
        selectedStashFile = file
        stashFileDiff = .loading
        let generation = stashGeneration
        let loader = stashLoader
        let target = repository.repository
        let worktree = focusedWorktreePath.flatMap { entry(at: $0)?.worktree }
        let source = DiffDocument.Source(label: stash.refName, kindLetter: file.isFromUntracked ? "?" : "")
        stashFileTask = Task { [weak self] in
            let result = await loader.patch(of: stash, file: file, in: target, worktree: worktree)
            guard let self, generation == self.stashGeneration, !Task.isCancelled, self.selectedStashFile == file
            else { return }
            switch result {
            case .patch(let patch):
                self.stashFileDiff = .loaded(DiffDocument(listing: patch, path: file.path, source: source))
            case .unavailable(let reason):
                self.stashFileDiff = .unavailable(reason)
            }
        }
    }

    /// Back to the graph from a stash file's diff (`⎋`).
    func clearStashFile() {
        stashFileTask?.cancel()
        selectedStashFile = nil
        stashFileDiff = nil
    }
}
