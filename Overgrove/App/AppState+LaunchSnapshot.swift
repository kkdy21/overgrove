import Foundation

/// The relaunch sidebar from the last session (ADR-0018, #109, T19).
extension AppState {
    /// Writes are spaced at least this far apart per repository (ADR-0018 §3).
    static let launchSnapshotSpacing: TimeInterval = 10

    /// Paints the last session's rows while the first load runs. Only `worktreeList` changes: no selection, focused
    /// worktree, toolbar snapshot, branches, or graph, so nothing can be opened or run from it (§5). The load that
    /// called this goes on as usual, inspection first.
    func showLaunchSnapshot(of repository: Repository, generation: Int) {
        guard let store = launchSnapshots, generation == loadGeneration, !Task.isCancelled,
            case .loading = worktreeList, let snapshot = store.load(for: repository)
        else { return }
        worktreeList = .snapshot(WorktreeListModel(snapshot: snapshot))
    }

    /// After a verified load: saves its rows for the next launch, at most once per `launchSnapshotSpacing` per
    /// repository; a newer listing replaces one still waiting.
    func scheduleLaunchSnapshot(_ listing: WorktreeListing, fingerprint: [LaunchSnapshot.FileStamp]?) {
        guard let store = launchSnapshots, let repository = repository?.repository else { return }
        launchSnapshotTask?.cancel()
        let focused = focusedWorktreePath
        let last = launchSnapshotWrites[repository.id] ?? .distantPast
        let wait = max(0, Self.launchSnapshotSpacing - Date().timeIntervalSince(last))
        let identity = gitIdentity
        launchSnapshotTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, let (executable, version) = await identity(), !Task.isCancelled else { return }
            // The repository may have closed, changed, or been removed (in another window or Settings) while waiting.
            guard let self, self.repository?.repository.id == repository.id, case .loaded = self.worktreeList,
                self.registry.repository(withID: repository.id) != nil
            else { return }
            guard
                let snapshot = LaunchSnapshot(
                    listing: listing, focused: focused, repository: repository, appVersion: store.appVersion,
                    gitExecutable: executable, gitVersion: version, fingerprint: fingerprint, now: Date())
            else { return }
            self.launchSnapshotWrites[repository.id] = Date()
            store.save(snapshot, for: repository)
        }
    }

    /// The open repository's snapshot, after a failed load (ADR-0018 §3).
    func deleteLaunchSnapshot() {
        guard let repository = repository?.repository else { return }
        launchSnapshotTask?.cancel()
        launchSnapshots?.delete(for: repository)
    }
}
