import Foundation
import Observation

/// Reads commit graph pages (ADR-0010 §3). The live loader pages with `--skip`/`-n`; #89 may swap in streaming.
protocol GraphLoading: Sendable {
    func page(_ repository: Repository, skip: Int, limit: Int) async -> Result<GraphPageSnapshot, GitError>
}

/// The app's graph loader: `RepositoryService.graphPage`, cached by ref set.
struct LiveGraphLoader: GraphLoading {
    let services: @Sendable () async throws -> (GitClient, RepositoryService)

    static let live = LiveGraphLoader(services: { try await LiveGitClient.shared.services() })

    func page(_ repository: Repository, skip: Int, limit: Int) async -> Result<GraphPageSnapshot, GitError> {
        do {
            let (_, service) = try await services()
            return await service.graphPage(repository, skip: skip, limit: limit)
        } catch let error as GitError {
            return .failure(error)
        } catch {
            return .failure(.executableNotFound(path: "git"))
        }
    }
}

/// The commit graph's state for the open repository (S-01 center, #68): pages loaded so far, their lane layout, ref
/// pills, the WIP row, and the selected commit.
///
/// Pages are laid out incrementally (`GraphEngine.layout(_:continuing:)`), so loading a page costs that page only.
/// A page read with another ref set than the loaded ones means the history moved: the graph starts over.
@MainActor
@Observable
final class GraphStore {
    enum Status: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    static let pageSize = 500
    /// Start the next page when the view shows a row this close to the end.
    static let prefetchDistance = 100

    private(set) var status: Status = .idle
    private(set) var commits: [CommitNode] = []
    private(set) var rows: [GraphRow] = []
    /// Lines below the last loaded row (`GraphLayoutState.pendingSegments`).
    private(set) var pendingSegments: [GraphSegment] = []
    private(set) var pills: [ObjectID: [GraphRefPill]] = [:]
    private(set) var wip: GraphWipRow?
    /// The focused worktree's HEAD, drawn with the accent ring.
    private(set) var head: ObjectID?
    private(set) var selected: ObjectID?
    /// A row to scroll into view (`⌘J`, keyboard moves); the token makes repeating the same row scroll again.
    private(set) var scrollTarget: ScrollTarget?

    struct ScrollTarget: Equatable {
        let oid: ObjectID
        let token: UUID
    }

    func scroll(to oid: ObjectID) {
        scrollTarget = ScrollTarget(oid: oid, token: UUID())
    }
    private(set) var isLoadingMore = false
    /// No more commits: the last page was short, or output was cut (pages after it would not line up).
    private(set) var isComplete = false
    /// Columns used by the loaded rows, for the Graph column width.
    private(set) var laneCount = 0

    private let loader: any GraphLoading
    private var repository: Repository?
    private var focus: WorktreeListing.Entry?
    private var refSet: GraphRefSet?
    private var refs = RefParser.Listing(branches: [], tags: [], isPartial: false, skippedRecords: 0)
    private var worktrees: [Worktree] = []
    private var layoutState = GraphLayoutState.initial
    private var indexByOID: [ObjectID: Int] = [:]
    private var generation = 0
    private var task: Task<Void, Never>?
    /// The pending first-page read only checks whether the history moved (`refresh`).
    private var isChecking = false

    init(loader: any GraphLoading = LiveGraphLoader.live) {
        self.loader = loader
    }

    /// Row index of `oid` among loaded commits.
    func index(of oid: ObjectID) -> Int? { indexByOID[oid] }

    /// Loads `repository`'s graph from the first page. `focus` decides the WIP row and the focused-branch pill.
    func load(_ repository: Repository, focus: WorktreeListing.Entry?) {
        self.repository = repository
        self.focus = focus
        restart()
    }

    /// The repository was refreshed: keep what is shown when the first page still has the same ref set, start over
    /// when it moved. Pages are cached by ref set, so an unchanged history reads nothing new.
    func refresh(focus: WorktreeListing.Entry?) {
        self.focus = focus
        decorate()
        guard status == .loaded else {
            if repository != nil { restart() }
            return
        }
        task?.cancel()
        generation += 1
        isLoadingMore = false
        isChecking = true
        fetch(skip: 0)
    }

    /// The focused worktree changed (or its status did): only decorations change, the history stays.
    func setFocus(_ focus: WorktreeListing.Entry?) {
        self.focus = focus
        decorate()
    }

    func select(_ oid: ObjectID?) {
        selected = oid
    }

    /// The view showed row `index`: load the next page when it is near the end.
    func rowAppeared(_ index: Int) {
        guard index >= rows.count - Self.prefetchDistance else { return }
        loadMore()
    }

    func clear() {
        task?.cancel()
        generation += 1
        repository = nil
        focus = nil
        reset()
        status = .idle
    }

    private func reset() {
        commits = []
        rows = []
        pendingSegments = []
        indexByOID = [:]
        layoutState = .initial
        refSet = nil
        isComplete = false
        isLoadingMore = false
        isChecking = false
        laneCount = 0
        selected = nil
    }

    private func restart() {
        task?.cancel()
        generation += 1
        reset()
        status = .loading
        fetch(skip: 0)
    }

    private func loadMore() {
        guard status == .loaded, !isComplete, !isLoadingMore else { return }
        isLoadingMore = true
        fetch(skip: commits.count)
    }

    private func fetch(skip: Int) {
        guard let repository else { return }
        let generation = generation
        let loader = loader
        task = Task { [weak self] in
            let result = await loader.page(repository, skip: skip, limit: Self.pageSize)
            guard let self, generation == self.generation, !Task.isCancelled else { return }
            self.receive(result, skip: skip)
        }
    }

    private func receive(_ result: Result<GraphPageSnapshot, GitError>, skip: Int) {
        isLoadingMore = false
        switch result {
        case .failure(.cancelled):
            return
        case .failure where isChecking:
            isChecking = false  // keep what is shown; the next refresh checks again
        case .failure(let error):
            if skip == 0 { status = .failed(PathValidator.displayable(error.message)) }
        // A later page failing keeps what is shown; scrolling to the end tries again.
        case .success(let page):
            if isChecking {
                isChecking = false
                guard page.refSet != refSet else { return }  // nothing moved: keep rows, selection, and scroll
                let selection = selected
                reset()
                append(page)
                selected = selection.flatMap { indexByOID[$0] == nil ? nil : $0 }
                return
            }
            if skip > 0, page.refSet != refSet {
                restart()  // the history moved since the first page
                return
            }
            append(page)
        }
    }

    private func append(_ page: GraphPageSnapshot) {
        let laid = GraphEngine.layout(page.commits, continuing: layoutState)
        for (offset, commit) in page.commits.enumerated() { indexByOID[commit.oid] = commits.count + offset }
        commits += page.commits
        rows += laid.rows
        for row in laid.rows {
            laneCount = max(laneCount, row.column + 1, (row.incoming.map { max($0.from, $0.to) }.max() ?? -1) + 1)
        }
        layoutState = laid.state
        pendingSegments = laid.state.pendingSegments
        isComplete = page.isPartial || page.commits.count < Self.pageSize
        if refSet != page.refSet {
            refSet = page.refSet
            refs = page.refs
            worktrees = page.worktrees
            decorate()
        }
        status = .loaded
    }

    private func decorate() {
        var known = worktrees
        if let focus, !known.contains(where: { $0.path == focus.worktree.path }) { known.append(focus.worktree) }
        pills = GraphRefDecorations.make(refs: refs, worktrees: known, focused: focus?.worktree.path)
        if let focus, case .loaded(let state) = focus.state {
            head = state.headCommit ?? focus.worktree.head
            wip = GraphWipRow.make(worktree: focus.worktree, state: state)
        } else {
            head = focus?.worktree.head
            wip = nil
        }
    }
}
