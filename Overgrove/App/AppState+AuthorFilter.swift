import Foundation

/// Which loaded history a cached author tally belongs to: a new page extends it, anything else rebuilds it.
struct GraphHistoryKey: Equatable {
    let commitCount: Int
    let newest: ObjectID?
    let decorationGeneration: Int

    @MainActor init(_ graph: GraphStore) {
        commitCount = graph.commits.count
        newest = graph.commits.first?.oid
        decorationGeneration = graph.decorationGeneration
    }

    func isExtension(of older: GraphHistoryKey) -> Bool {
        newest == older.newest && decorationGeneration == older.decorationGeneration
            && commitCount > older.commitCount
    }
}

/// The graph's author filter chips (#255, screens.md S-01). In memory over the loaded pages: no git runs.
extension AppState {
    /// The chips for the loaded pages; `nil` until the graph has loaded.
    var graphAuthorSummary: GraphAuthorSummary? {
        guard graph.status == .loaded else { return nil }
        let key = GraphHistoryKey(graph)
        if let cached = authorSummaryCache, cached.key == key { return cached.summary }
        let summary =
            if let cached = authorSummaryCache, key.isExtension(of: cached.key) {
                cached.summary.extended(with: graph.commits)
            } else {
                GraphAuthorSummary(commits: graph.commits)
            }
        authorSummaryCache = (key, summary)
        return summary
    }

    /// The loaded commits the picked chip keeps bright; `nil` for `All`.
    var graphAuthorFilter: GraphAuthorFilterResult? {
        guard authorFilter != .all, graph.status == .loaded else { return nil }
        let key = GraphHistoryKey(graph)
        if let cached = authorFilterCache, cached.key == key, cached.result.selection == authorFilter {
            return cached.result
        }
        let result: GraphAuthorFilterResult?
        if let cached = authorFilterCache, cached.result.selection == authorFilter, key.isExtension(of: cached.key) {
            result = cached.result.extended(with: graph.commits)
        } else {
            result = GraphAuthorFilterResult(selection: authorFilter, commits: graph.commits)
        }
        if let result { authorFilterCache = (key, result) }
        return result
    }

    /// A chip was clicked. Picking the chosen chip again goes back to `All`.
    func selectAuthorFilter(_ selection: GraphAuthorSelection) {
        authorFilter = selection == authorFilter ? .all : selection
    }
}
