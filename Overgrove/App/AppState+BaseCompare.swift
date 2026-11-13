import Foundation

/// The base compare card under S-02 and S-05 (#581, art-direction.md §7).
///
/// It runs S-11's default comparison for the focused worktree (the remembered or preferred base, uncommitted changes
/// included), so its values match S-11 and the two share `RepositoryService`'s comparison cache: opening S-11 right
/// after shows the cached result.
///
/// Git work does not pile up while the user moves through worktrees:
/// - a request waits `baseSummaryDebounce` first; a new request in that time restarts the wait, so stepping through
///   worktrees runs nothing until the selection settles;
/// - once the commands run, a request for the same worktree only marks one more comparison for when they end (as S-11
///   does, #412), and a request for another worktree cancels them;
/// - nothing runs while S-11 is open (it covers the card) or before the worktree's status is loaded.
///
/// Auto refresh does not drive it at its own pace: every refresh re-reads the focused worktree's status, which is part
/// of the cache key, so each one would cost a comparison. On a large repository that is about 20 times a status
/// (PERF-10b: 650 ms against 33 ms). A request from auto refresh (`throttled`) therefore waits until
/// `baseSummaryThrottleGap` after the last comparison ended: at least 5 s, or ten times that comparison's duration,
/// the same rule auto refresh applies to itself (interaction.md §4). What the user does (selecting, picking a base,
/// ⌘R, closing S-11) only waits for the debounce.
extension AppState {
    /// How long a card request waits for the selection to settle.
    static let baseSummaryDebounce: Duration = .milliseconds(300)
    /// The least time between an auto-refresh comparison and the previous one; also the most a change waits when the
    /// card was idle for longer (the same 5 s as auto refresh's longest wait).
    static let baseSummaryMinimumGap: Duration = .seconds(5)

    /// The card for the focused worktree, `nil` when there is none.
    var baseCompareCardModel: BaseCompareCardModel? {
        guard let path = focusedWorktreePath else { return nil }
        let summary = baseSummary?.worktree == path ? baseSummary : nil
        return BaseCompareCardModel(summary: summary, canCompare: canCompare(path))
    }

    /// How long after the last comparison ended an auto-refresh comparison may start: max(5 s, 10 × its duration).
    var baseSummaryThrottleGap: Duration {
        max(Self.baseSummaryMinimumGap, (baseSummaryLastDuration ?? .zero) * 10)
    }

    /// Compares the focused worktree with its base for the card.
    /// - Parameters:
    ///   - immediately: Skips the debounce (a base the user picked).
    ///   - throttled: The request came from auto refresh: it also waits out `baseSummaryThrottleGap`. A user request
    ///     waiting or pending is never slowed down by one.
    func refreshBaseSummary(immediately: Bool = false, throttled: Bool = false) {
        guard let loader = baseSummaryLoader, let repository, comparison == nil,
            let path = focusedWorktreePath, canCompare(path)
        else { return }
        let isSameWorktree = baseSummary?.worktree == path
        if isSameWorktree, isBaseSummaryComparing {
            // One more when the commands end; it is throttled only if every request since was.
            isBaseSummaryRerunThrottled =
                isBaseSummaryRerunPending ? isBaseSummaryRerunThrottled && throttled : throttled
            isBaseSummaryRerunPending = true
            return
        }
        // A user request already waiting covers this one, sooner.
        if isSameWorktree, throttled, baseSummaryTask != nil, !isBaseSummaryWaitThrottled { return }
        baseSummaryTask?.cancel()
        baseSummaryGeneration += 1
        isBaseSummaryComparing = false
        isBaseSummaryRerunPending = false
        isBaseSummaryWaitThrottled = throttled
        if !isSameWorktree {
            baseSummary = BaseCompareSummary(worktree: path, base: comparisonBases[path])
        }
        let generation = baseSummaryGeneration
        let chosen = comparisonBases[path]
        let target = repository.repository
        var wait: Duration = immediately ? .zero : Self.baseSummaryDebounce
        if throttled, let ended = baseSummaryLastEnded {
            wait = max(wait, ended + baseSummaryThrottleGap - ContinuousClock.now)
        }
        baseSummaryTask = Task { [weak self] in
            if wait > .zero {
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled else { return }
            }
            guard let self, generation == self.baseSummaryGeneration else { return }
            self.isBaseSummaryComparing = true
            let started = ContinuousClock.now
            let bases = await loader.bases(of: target)
            let base = chosen ?? bases.preferred
            let result: Result<WorktreeComparison, ComparisonError> =
                if let base {
                    await loader.compare(target, worktree: path, base: base, includeUncommitted: true)
                } else {
                    .failure(.noBaseBranch)
                }
            guard generation == self.baseSummaryGeneration, !Task.isCancelled else { return }
            let ended = ContinuousClock.now
            self.baseSummaryLastEnded = ended
            self.baseSummaryLastDuration = ended - started
            self.isBaseSummaryComparing = false
            self.baseSummaryTask = nil
            self.baseSummary?.bases = bases.all
            switch result {
            case .success(let comparison):
                self.baseSummary?.base = comparison.base
                self.baseSummary?.result = .loaded(comparison)
            case .failure(let error):
                self.baseSummary?.base = base
                self.baseSummary?.result = .failed(error)
            }
            if self.isBaseSummaryRerunPending {
                self.isBaseSummaryRerunPending = false
                self.refreshBaseSummary(throttled: self.isBaseSummaryRerunThrottled)
            }
        }
    }

    /// The card's base menu: remembered for the worktree like S-11's choice, so S-11 opens on it too.
    func chooseBaseSummaryBase(_ base: FullRefName) {
        guard let path = focusedWorktreePath, baseSummary?.worktree == path,
            baseSummary?.bases.contains(base) == true
        else { return }
        comparisonBases[path] = base
        baseSummary?.base = base
        baseSummary?.result = .loading
        // A different base is a new comparison: what ran for the old one is dropped.
        isBaseSummaryComparing = false
        isBaseSummaryRerunPending = false
        refreshBaseSummary(immediately: true)
    }

    /// S-11 opened over the card: the card's own comparison stops (S-11 runs the same one).
    func pauseBaseSummary() {
        baseSummaryTask?.cancel()
        baseSummaryTask = nil
        baseSummaryGeneration += 1
        isBaseSummaryComparing = false
        isBaseSummaryRerunPending = false
    }
}
