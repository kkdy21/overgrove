import Foundation

/// Comparing two commits (S-12, #388, screens.md S-12): the selected commit is the base, the row whose menu opened it is
/// the target. It covers the graph like S-11; the main selection stays the base, and nothing here is recorded in the
/// selection history.
extension AppState {
    /// S-12's rows, `nil` without an open comparison.
    var commitComparisonModel: CommitComparisonModel? {
        guard let session = commitComparison else { return nil }
        let graph = graph
        return CommitComparisonModel(session: session, graphHasEveryCommit: graph.hasEveryCommit) { oid in
            graph.index(of: oid).map { graph.commits[$0] }
        }
    }

    private func loadedCommit(_ oid: ObjectID) -> CommitNode? {
        graph.index(of: oid).map { graph.commits[$0] }
    }

    /// `Compare with Selected Commit` is on: another commit is the main selection, and both are loaded in the graph.
    func canCompareCommit(with target: ObjectID) -> Bool {
        guard case .commit(let base) = selection, base != target, graph.index(of: base) != nil,
            graph.index(of: target) != nil
        else { return false }
        return true
    }

    func showCommitComparison(with target: ObjectID) {
        guard case .commit(let base) = selection, canCompareCommit(with: target) else { return }
        // S-11, an older S-12, S-09, and a diff close first.
        closeComparison()
        history.close()
        clearSelectedFile()
        commitComparison = CommitComparisonSession(
            base: base, target: target, baseNode: loadedCommit(base), targetNode: loadedCommit(target))
        loadCommitComparison()
    }

    /// `⇄`: the target becomes the base.
    func swapCommitComparison() {
        guard let session = commitComparison else { return }
        commitComparison = CommitComparisonSession(
            base: session.target, target: session.base, baseNode: session.targetNode, targetNode: session.baseNode)
        loadCommitComparison()
    }

    /// Back to the graph (`‹ Graph`, `⎋`).
    func closeCommitComparison() {
        commitComparisonTask?.cancel()
        commitComparisonPatchTask?.cancel()
        commitComparisonTask = nil
        commitComparisonPatchTask = nil
        commitComparisonGeneration += 1
        commitComparison = nil
    }

    func showAllCommitComparisonFiles() {
        commitComparison?.showsAllFiles = true
    }

    /// A BASE or TARGET row: S-12 closes and that commit's S-03 opens. A commit no longer in the graph (#428) has
    /// nothing to open, so S-12 stays.
    func showCommitFromComparison(_ oid: ObjectID) {
        guard graph.index(of: oid) != nil else { return }
        closeCommitComparison()
        selectCommit(oid)
        graph.scroll(to: oid)
    }

    private func loadCommitComparison() {
        guard let session = commitComparison, let repository else { return }
        commitComparisonTask?.cancel()
        commitComparisonPatchTask?.cancel()
        commitComparisonGeneration += 1
        let generation = commitComparisonGeneration
        let loader = commitLoader
        let target = repository.repository
        commitComparisonTask = Task { [weak self] in
            // The file list and the commits between (#389) run together; each shows when it is ready.
            async let commits = loader.commits(target, from: session.base, to: session.target)
            let files = await loader.files(target, from: session.base, to: session.target)
            self?.finishCommitComparisonFiles(files, generation: generation)
            let range = await commits
            self?.finishCommitComparisonCommits(range, generation: generation)
        }
    }

    private func finishCommitComparisonFiles(_ result: Result<NumstatParser.Files, GitError>, generation: Int) {
        guard generation == commitComparisonGeneration, !Task.isCancelled else { return }
        switch result {
        case .success(let files): commitComparison?.files = .loaded(files)
        // A cancelled read is not a failure to show (as in `CommitDetailStore`).
        case .failure(.cancelled): break
        case .failure(let error): commitComparison?.files = .failed(error.message)
        }
    }

    private func finishCommitComparisonCommits(_ result: Result<LogParser.GraphPage, GitError>, generation: Int) {
        guard generation == commitComparisonGeneration, !Task.isCancelled else { return }
        switch result {
        case .success(let page): commitComparison?.commits = .loaded(page)
        case .failure(.cancelled): break
        case .failure(let error): commitComparison?.commits = .failed(error.message)
        }
    }

    /// A file in FILES CHANGED: its patch from base to target in the center (S-10's viewer).
    func selectCommitComparisonFile(_ stat: FileStat) {
        guard let session = commitComparison, let repository, case .loaded(let list) = session.files,
            let row = list.files.first(where: { $0.path == stat.path }),
            CommitDetailModel.fileRow(row).isSelectable
        else { return }
        commitComparisonPatchTask?.cancel()
        commitComparison?.selectedFile = row.path
        commitComparison?.patch = .loading
        let generation = commitComparisonGeneration
        let loader = commitLoader
        let target = repository.repository
        let source = DiffDocument.Source(
            label: "\(session.base.short) → \(session.target.short)",
            kindLetter: CommitDetailModel.fileRow(row).kindLetter)
        commitComparisonPatchTask = Task { [weak self] in
            let result = await loader.patch(
                target, of: session.target, parent: session.base, path: row.path, originalPath: row.originalPath)
            guard let self, generation == self.commitComparisonGeneration, !Task.isCancelled,
                self.commitComparison?.selectedFile == row.path
            else { return }
            switch result {
            case .success(let patch):
                self.commitComparison?.patch = .loaded(DiffDocument(listing: patch, path: row.path, source: source))
            case .failure(.cancelled):
                break
            case .failure(let error):
                self.commitComparison?.patch = .unavailable(PathValidator.displayable(error.message))
            }
        }
    }
}
