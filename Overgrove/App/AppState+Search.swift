import Foundation

/// What a cached search result depends on: the query and the loaded graph (pages, refs, issue repository).
struct SearchCacheKey: Equatable {
    let query: GraphSearchQuery
    let commitCount: Int
    let newest: ObjectID?
    let decorationGeneration: Int
    let isComplete: Bool
    let issueRepository: String?

    /// The same search over the same history with more pages loaded: the result can be extended.
    func isExtension(of older: SearchCacheKey) -> Bool {
        query == older.query && newest == older.newest && decorationGeneration == older.decorationGeneration
            && issueRepository == older.issueRepository && commitCount > older.commitCount
    }
}

/// Toolbar search over the loaded graph and the sidebar filter (#74, screens.md S-01). In memory: no git runs.
extension AppState {
    /// The search over the loaded pages, `nil` without a query. Reused until the query, the history, or the refs
    /// change; a new page only adds its own commits (security review of #74, T15).
    var graphSearch: GraphSearchResult? {
        guard let query = GraphSearchQuery(searchText), graph.status == .loaded else { return nil }
        let key = SearchCacheKey(
            query: query, commitCount: graph.commits.count, newest: graph.commits.first?.oid,
            decorationGeneration: graph.decorationGeneration, isComplete: graph.isComplete,
            issueRepository: issuePanel.repository?.slug)
        if let cached = searchCache, cached.key == key { return cached.result }
        let result: GraphSearchResult
        if let cached = searchCache, key.isExtension(of: cached.key) {
            result = cached.result.extended(
                with: graph.commits, pills: graph.pills, issueRepository: key.issueRepository,
                isComplete: graph.isComplete)
        } else {
            result = GraphSearchResult(
                query: query, commits: graph.commits, pills: graph.pills, issueRepository: key.issueRepository,
                isComplete: graph.isComplete)
        }
        searchCache = (key, result)
        return result
    }

    /// ⌘G / ⏎ in the field: selects the next match (S-03) and scrolls the graph to it, wrapping around.
    func findNext() {
        findMatch(forward: true)
    }

    /// ⌘⇧G.
    func findPrevious() {
        findMatch(forward: false)
    }

    var canFindMatch: Bool { !(graphSearch?.matches.isEmpty ?? true) }

    private func findMatch(forward: Bool) {
        guard let result = graphSearch, let oid = result.step(from: graph.selected, forward: forward) else { return }
        // The graph shows again: `selectCommit` closes a diff or comparison covering it, and a file history closes.
        history.close()
        selectCommit(oid)
        graph.scroll(to: oid)
    }

    /// Edit › Filter Sidebar (⌥⌘F).
    func focusSidebarFilter() {
        sidebarFilterFocusRequest += 1
    }
}
