import Foundation

/// Worktree list, selection, refresh triggers, and the worktree detail (S-05). Moved out of `AppState.swift` unchanged (#253).
extension AppState {
    // MARK: Worktrees (#65)

    /// Inspects the open repository and loads everything again (`.user`: opening a repository, ⌘R; overview.md §3.2).
    /// When the repository is not shown yet, its cached listing (no git) is painted first (PB-2). A newer request
    /// cancels this one, and its result is dropped.
    func reload() {
        issuePanel.markStale()
        refresh(.user)
    }

    /// The window became key (interaction.md §4): `.automatic` (debounced), once loaded and while no load runs.
    func windowDidBecomeActive() {
        guard repository != nil, runningTrigger == nil else { return }
        // The first load was superseded every time (another window): load everything.
        if needsFullLoad { return refresh(.user) }
        guard hasVerifiedListing, case .loaded = worktreeList else { return }
        refresh(.automatic)
    }

    /// Superseded first loads retried before falling back to Loading.
    static let maximumSupersededRetries = 2

    /// Starts a refresh for `trigger` (overview.md §5 decides what it re-queries). A full refresh in flight is not
    /// replaced by a narrower one: it already brings everything.
    func refresh(_ trigger: RepositoryService.Trigger) {
        guard let repository else { return }
        if trigger != .user, runningTrigger == .user { return }
        // An auto refresh in flight is replaced: its changes are kept and sent again (#119).
        if case .filesChanged = runningTrigger { autoRefresh.requestSuperseded() }
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        runningTrigger = trigger
        let isShown: Bool = if case .loaded = worktreeList { true } else { false }
        if !isShown {
            worktreeList = .loading
            branchListModel = nil
        }
        let loader = loader
        let target = repository.repository
        loadTask = Task { [weak self] in
            if !isShown, let cached = await loader.cachedListing(target) {
                self?.showCached(cached, generation: generation)
            } else if !isShown, trigger == .user {
                // Nothing in memory (a relaunch): the last session's sidebar, display only (ADR-0018 §5).
                self?.showLaunchSnapshot(of: target, generation: generation)
            }
            // Taken before the load, so what changes during it makes the next launch's snapshot stale (ADR-0018 §3).
            let fingerprint =
                self?.launchSnapshots == nil ? nil : LaunchSnapshot.fingerprint(target.commonGitDirectoryURL)
            let result: Result<WorktreeListing?, RepositoryLoadError>
            do throws(RepositoryLoadError) {
                result = .success(try await loader.load(target, trigger: trigger))
            } catch {
                result = .failure(error)
            }
            self?.finishLoad(result, generation: generation, fingerprint: fingerprint)
        }
    }

    /// Paints a cached listing while the refresh that follows it runs.
    private func showCached(_ listing: WorktreeListing, generation: Int) {
        guard generation == loadGeneration, !Task.isCancelled else { return }
        if case .loaded = worktreeList { return }
        apply(listing, isVerified: false)
    }

    private func finishLoad(
        _ result: Result<WorktreeListing?, RepositoryLoadError>, generation: Int,
        fingerprint: [LaunchSnapshot.FileStamp]? = nil
    ) {
        guard generation == loadGeneration, !Task.isCancelled else { return }
        let finished = runningTrigger
        runningTrigger = nil
        defer {
            if let finished {
                let outcome: AutoRefreshController.LoadOutcome =
                    switch result {
                    case .success(.some): .succeeded
                    case .success(nil), .failure(.git(.cancelled)): .superseded
                    case .failure: .failed
                    }
                autoRefresh.loadFinished(finished, outcome: outcome)
            }
        }
        switch result {
        case .success(let listing?):
            hasVerifiedListing = true
            supersededRetries = 0
            needsFullLoad = false
            apply(listing, isVerified: true)
            // Loads that brought the whole sidebar (ADR-0018 §3), not a single worktree or a file event.
            switch finished {
            case .user?, .automatic?, .fetchCompleted?:
                scheduleLaunchSnapshot(listing, fingerprint: fingerprint)
            default:
                break
            }
        case .success(nil), .failure(.git(.cancelled)):
            // Superseded (another window asked for the same repository) or debounced away. A verified listing stays;
            // a cached paint is not kept as if it were current (security review of #243).
            guard !hasVerifiedListing else { break }
            if supersededRetries < Self.maximumSupersededRetries {
                supersededRetries += 1
                refresh(.user)
            } else {
                worktreeList = .loading
                branchListModel = nil
                snapshot = nil
                needsFullLoad = true
            }
        case .failure(let error):
            // The message can carry masked stderr, which still keeps separators such as U+2028.
            worktreeList = .failed(message: PathValidator.displayable(error.message))
            branchListModel = nil
            snapshot = nil
            // The memory cache is dropped on failure (overview.md §5); so is the snapshot (ADR-0018 §3).
            deleteLaunchSnapshot()
        }
    }

    /// First load reads the graph; later loads keep it unless the history moved (GraphStore.refresh).
    private func updateGraph(_ listing: WorktreeListing) {
        let focus = listing.entries.first { $0.worktree.path == focusedWorktreePath }
        if graph.status == .idle, let repository {
            graph.load(repository.repository, focus: focus)
        } else {
            graph.refresh(focus: focus)
        }
    }

    /// - Parameter isVerified: The listing came from this load's inspection, not from the cache painted before it.
    private func apply(_ listing: WorktreeListing, isVerified: Bool) {
        worktreeList = .loaded(listing)
        // Watch only what this load verified (#226), never a cached paint (#119).
        if isVerified, let repository {
            autoRefresh.update(FileChangeClassifier(listing: listing, repository: repository.repository))
        }
        branchListModel = Self.branchModel(listing)
        issueLinks = IssueLinkIndex(listing: listing)
        focusedWorktreePath = WorktreeListModel.focusedPath(in: listing, requested: focusedWorktreePath)
        if let path = selection?.worktreePath, path != focusedWorktreePath { selection = nil }
        // S-11 belongs to one worktree; if it is gone (removed in Terminal), the comparison closes too (#311).
        if let compared = comparison?.worktree, !listing.entries.contains(where: { $0.worktree.path == compared }) {
            closeComparison()
        }
        // A stash that is gone (dropped or applied elsewhere) falls back to the focused worktree.
        if case .stash(let oid) = selection, !listing.stashes.contains(where: { $0.oid == oid }) {
            selection = nil
        }
        selection = selection ?? focusedWorktreePath.map(MainSelection.wip)
        // A stash's content never changes (it is addressed by OID): keep the loaded detail and the open file.
        if case .stash(let oid) = selection, loadedStashOID != oid { loadStash() }
        // Configuration may have changed since the last inspection.
        worktreeInspections = [:]
        inspectionGeneration += 1
        if case .worktreeInfo = selection { inspectSelectedWorktree() }
        // Only this load's inspected remotes pick the repository gh is asked about, never a cached paint (even after
        // a failed refresh; security review of #81).
        // gh's login state is read alongside, for the status bar (#83); a repository without a GitHub remote runs no gh.
        if isVerified, issuePanel.show(listing.githubRepository) { checkGitHub() }
        snapshot = WorktreeListModel.snapshot(listing: listing, focused: focusedWorktreePath)
        updateGraph(listing)
        // Keep the picked file only while it is still listed in the same group.
        // Same rule as `selectFile`: the row must still exist and still be selectable.
        if let file = selectedFile, wipDetailModel?.row(for: file)?.isSelectable != true {
            selectedFile = nil
        } else if selectedFile != nil {
            // Same file, new content: load its diff again.
            loadDiff()
        }
        // The load may have re-queried the status even if it reads the same (an edit inside a modified file).
        requestLineCounts(refresh: true)
    }

    /// The sidebar row model, `nil` until the list has loaded.
    var worktreeListModel: WorktreeListModel? {
        if case .snapshot(let model) = worktreeList { return model }
        guard case .loaded(let listing) = worktreeList else { return nil }
        let graph = graph
        return WorktreeListModel(listing: listing, focused: focusedWorktreePath, laneIndex: graph.laneIndex(of:))
    }

    #if DEBUG
        /// Shows `listing` as if it had just loaded (previews and render tests; no git).
        func showForPreview(_ listing: WorktreeListing) {
            hasVerifiedListing = true
            apply(listing, isVerified: false)
        }
    #endif

    /// Selecting a worktree row focuses that worktree and shows its changes (interaction.md §1.3). What is shown
    /// comes from the listing in memory (the service's cached overview) at once (PB-2); that worktree's status is
    /// then refreshed in the background (`.worktreeSelected`, overview.md §5).
    func selectWorktree(_ path: GitPath) {
        guard case .loaded(let listing) = worktreeList, listing.entries.contains(where: { $0.worktree.path == path })
        else { return }
        // The center goes back to the graph (information-architecture.md §2.2), so an open file history closes.
        history.close()
        graph.select(nil)
        commitDetail.clearFile()
        if focusedWorktreePath != path {
            selectedFile = nil
            // S-11 belongs to one worktree.
            if comparison?.worktree != path { closeComparison() }
        }
        focusedWorktreePath = path
        snapshot = WorktreeListModel.snapshot(listing: listing, focused: path)
        graph.setFocus(listing.entries.first { $0.worktree.path == path })
        // The segment the user chose stays when they move to another worktree; `Changes` is the default.
        if case .worktreeInfo = selection {
            selection = .worktreeInfo(path)
            inspectSelectedWorktree()
        } else {
            selection = .wip(path)
            requestLineCounts()
        }
        refresh(.worktreeSelected(path))
    }

    // MARK: Worktree detail (#67)

    /// The `Changes | Worktree` segment.
    func showChanges() {
        guard let path = selection?.worktreePath else { return }
        selection = .wip(path)
        requestLineCounts()
    }

    func showWorktreeDetail() {
        guard let path = selection?.worktreePath else { return }
        selection = .worktreeInfo(path)
        inspectSelectedWorktree()
    }

    /// S-05 for the selected worktree, `nil` unless its `Worktree` segment is shown.
    var worktreeDetailModel: WorktreeDetailModel? {
        guard case .worktreeInfo(let path) = selection, let entry = entry(at: path) else { return nil }
        return WorktreeDetailModel(
            entry: entry, inspection: worktreeInspections[path], fetchStatus: fetchStatus, now: Date(),
            showsFullRemoteURLs: settings.showsFullRemoteURLs, isUntrusted: isRepositoryUntrusted)
    }

    /// The open repository is marked untrusted (#107, the registry's flag).
    var isRepositoryUntrusted: Bool {
        repository.flatMap { registry.repository(withID: $0.repository.id)?.isUntrusted } ?? false
    }

    /// The S-05 toggle: marks the open repository untrusted, or trusted again (#107). A fetch already running stops
    /// when the repository becomes untrusted (`observeUntrustedFlag`).
    func setRepositoryUntrusted(_ isUntrusted: Bool) {
        guard let repository else { return }
        registry.setUntrusted(isUntrusted, for: repository.repository.id)
    }

    /// A fetch reads the untrusted flag when it starts. When the open repository becomes untrusted while one runs,
    /// from S-05, Settings, or another window, it stops, so no later remote is fetched as trusted (security review of
    /// #107). Re-registers after every change, as `withObservationTracking` reports one change at a time.
    func observeUntrustedFlag() {
        withObservationTracking {
            _ = isRepositoryUntrusted
        } onChange: { [weak self] in
            // Called before the change is stored: read the new value on the next turn.
            Task { @MainActor in
                guard let self else { return }
                if self.isRepositoryUntrusted && self.fetch.status.isFetching { self.fetch.stop() }
                self.observeUntrustedFlag()
            }
        }
    }

    /// Sidebar REMOTE group tooltips (#86): remote name → its URL as the Show full remote URLs setting says. Built
    /// from the masked URLs of an inspected worktree's configuration (remotes are shared by every worktree).
    var remoteURLTooltips: [String: String] {
        guard case .loaded(let listing) = worktreeList,
            let inspection = listing.entries.lazy.compactMap(\.inspection).first
        else { return [:] }
        let full = settings.showsFullRemoteURLs
        return Dictionary(
            inspection.remotes.map { ($0.name.value, RemoteURLDisplay.text($0.displayURL, full: full)) },
            uniquingKeysWith: { first, _ in first })
    }

    func entry(at path: GitPath) -> WorktreeListing.Entry? {
        guard case .loaded(let listing) = worktreeList else { return nil }
        return listing.entries.first { $0.worktree.path == path }
    }

    /// Reads the shown worktree's configuration once per load, only for worktrees `RepositoryService` verified.
    private func inspectSelectedWorktree() {
        guard case .worktreeInfo(let path) = selection, worktreeInspections[path] == nil,
            let entry = entry(at: path), WorktreeDetailModel.shouldInspect(entry), let repository
        else { return }
        let generation = inspectionGeneration
        let inspector = inspector
        let target = repository.repository
        inspectionTask?.cancel()
        inspectionTask = Task { [weak self] in
            let result = await inspector.inspect(entry, of: target)
            guard let self, generation == self.inspectionGeneration, !Task.isCancelled else { return }
            self.worktreeInspections[path] = result
        }
    }
}
