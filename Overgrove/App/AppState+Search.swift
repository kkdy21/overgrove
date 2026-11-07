import Foundation

/// What a cached search result depends on: the query and the loaded graph (pages, refs, issue repository).
struct SearchCacheKey: Equatable {
    let query: GraphSearchQuery
    let commitCount: Int
    let newest: ObjectID?
    let pillCount: Int
    let isComplete: Bool
    let issueRepository: String?
}

/// Toolbar search over the loaded graph and the sidebar filter (#74, screens.md S-01). In memory: no git runs.
extension AppState {
    /// The search over the loaded pages, `nil` without a query. Rebuilt only when the query or the pages change
    /// (one pass over the loaded commits).
    var graphSearch: GraphSearchResult? {
        guard let query = GraphSearchQuery(searchText), graph.status == .loaded else { return nil }
        let key = SearchCacheKey(
            query: query, commitCount: graph.commits.count, newest: graph.commits.first?.oid,
            pillCount: graph.pills.count, isComplete: graph.isComplete, issueRepository: issuePanel.repository?.slug)
        if let cached = searchCache, cached.key == key { return cached.result }
        let result = GraphSearchResult(
            query: query, commits: graph.commits, pills: graph.pills, issueRepository: key.issueRepository,
            isComplete: graph.isComplete)
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
        // `selectCommit` also closes a diff or comparison covering the graph.
        selectCommit(oid)
        graph.scroll(to: oid)
    }

    /// Edit › Filter Sidebar (⌥⌘F).
    func focusSidebarFilter() {
        sidebarFilterFocusRequest += 1
    }
}
