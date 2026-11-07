import Foundation

/// S-09's state (#70): the open file history, its pages, and the selected row. Pages are cached per worktree, path,
/// HEAD, and follow setting, so going back to a file's history does not run git again until HEAD moves.
@MainActor
@Observable
final class FileHistoryStore {
    enum Status: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    /// First page and each further page (screens.md S-09: the first 500, more on scroll).
    static let pageSize = 500
    /// Rows before the end at which the next page starts loading.
    static let prefetchDistance = 100
    /// Histories kept for going back (each up to the pages loaded).
    static let cacheCapacity = 8

    private(set) var target: FileHistoryTarget?
    private(set) var entries: [FileHistoryEntry] = []
    private(set) var status: Status = .loading
    /// git returned fewer than a page: this is the first commit of the file.
    private(set) var isComplete = false
    /// The output limit cut the history: older commits exist but cannot be listed (not the beginning).
    private(set) var isCutAtLimit = false
    private(set) var isLoadingMore = false
    /// A further page failed; it is not asked again until Retry (no new git on every scroll).
    private(set) var loadMoreError: String?
    private(set) var selected: ObjectID?
    /// The load in flight; tests await it.
    private(set) var task: Task<Void, Never>?

    private let loader: any FileHistoryLoading
    private var generation = 0
    private var cache = BoundedCache<FileHistoryTarget.Key, Snapshot>(capacity: cacheCapacity)

    private struct Snapshot: Sendable {
        let entries: [FileHistoryEntry]
        let isComplete: Bool
        let isCutAtLimit: Bool
    }

    init(loader: any FileHistoryLoading) {
        self.loader = loader
    }

    var isOpen: Bool { target != nil }

    /// Opens `target`'s history: from the cache when this worktree's HEAD has not moved, otherwise its first page.
    func open(_ target: FileHistoryTarget) {
        cancel()
        self.target = target
        selected = nil
        loadMoreError = nil
        if let snapshot = cache.value(for: target.key) {
            entries = snapshot.entries
            isComplete = snapshot.isComplete
            isCutAtLimit = snapshot.isCutAtLimit
            status = .loaded
            return
        }
        entries = []
        isComplete = false
        isCutAtLimit = false
        status = .loading
        fetch(skip: 0)
    }

    /// Follow renames on or off (another key, so another history).
    func setFollow(_ follow: Bool) {
        guard var target, target.follow != follow else { return }
        target.follow = follow
        open(target)
    }

    func select(_ oid: ObjectID?) {
        selected = oid
    }

    /// A row came into view; near the end, the next page loads.
    func rowAppeared(_ index: Int) {
        guard status == .loaded, !isComplete, !isLoadingMore, loadMoreError == nil,
            index >= entries.count - Self.prefetchDistance
        else { return }
        isLoadingMore = true
        fetch(skip: entries.count)
    }

    /// Retry after a further page failed.
    func retryLoadMore() {
        guard loadMoreError != nil, !isLoadingMore else { return }
        loadMoreError = nil
        isLoadingMore = true
        fetch(skip: entries.count)
    }

    func close() {
        cancel()
        target = nil
        entries = []
        selected = nil
        status = .loading
        isComplete = false
        isCutAtLimit = false
        loadMoreError = nil
    }

    /// Another repository opened: nothing cached belongs to it.
    func reset() {
        close()
        cache = BoundedCache(capacity: Self.cacheCapacity)
    }

    private func cancel() {
        task?.cancel()
        task = nil
        generation += 1
        isLoadingMore = false
    }

    private func fetch(skip: Int) {
        guard let target else { return }
        let generation = generation
        let loader = loader
        task = Task { [weak self] in
            let result = await loader.page(target, skip: skip, limit: Self.pageSize)
            guard let self, generation == self.generation, !Task.isCancelled else { return }
            self.receive(result, for: target)
        }
    }

    private func receive(_ result: FileHistoryLoadResult, for target: FileHistoryTarget) {
        isLoadingMore = false
        switch result {
        case .page(let page):
            // HEAD can move between pages (git reads the current HEAD); a commit already listed is not listed twice.
            let shown = Set(entries.map(\.id))
            entries += page.entries.filter { !shown.contains($0.id) }
            // A cut page is not the end: the next one continues after what was kept. One that kept nothing cannot
            // advance: the list stops there, marked as cut at the limit, not as the beginning of the history.
            if page.isPartial {
                isCutAtLimit = page.entries.isEmpty
                isComplete = isCutAtLimit
            } else {
                isComplete = page.entries.count < Self.pageSize
            }
            status = .loaded
            cache.insert(
                Snapshot(entries: entries, isComplete: isComplete, isCutAtLimit: isCutAtLimit), for: target.key)
        case .unavailable(let reason):
            if entries.isEmpty { status = .failed(reason) } else { loadMoreError = reason }
        case .cancelled:
            break
        }
    }
}
