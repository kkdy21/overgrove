/// Computes commit graph lanes from commit order and parent lists (ADR-0010).
///
/// Pure logic: no git, no UI, no I/O. The input is `git log --date-order` order (newest first); refs/stash is already
/// excluded by the command.
///
/// Rules:
/// - A commit goes on the leftmost lane waiting for it. Other lanes waiting for it end there (branch edges). If no lane
///   waits for it (a branch tip or an unrelated history), it opens a lane in the leftmost free column.
/// - The first parent continues the commit's lane. Each further parent joins the leftmost lane already waiting for it,
///   or opens a new lane in the leftmost free column (merge edges, octopus merges).
/// - A root commit ends its lane. A parent that never appears keeps its lane open (shallow or cut history).
/// - Lanes never move sideways, so lines stay straight; a freed column is reused by the next new lane.
/// - A lane's color is the column it was created in, mod 8 (`graph.lane.0`…`graph.lane.7`), for its whole life.
///
/// Each commit costs O(active lanes + parents), so a page of n commits costs O(n · active lanes).
enum GraphEngine {
    static let laneColorCount = 8

    /// Lays out `commits`, continuing from `state`.
    ///
    /// For paging (ADR-0010 §3), pass the previous page's `state`; the result is identical to laying out both pages in
    /// one call. Start again from `.initial` when the ref set changes.
    static func layout(_ commits: [CommitNode], continuing state: GraphLayoutState = .initial) -> GraphLayoutPage {
        // The state is copied and advanced locally: mutating one uniquely owned lane array in place keeps each row
        // O(active lanes) instead of rebuilding the array per commit. Nothing outside this call sees the mutation.
        var current = state
        var rows: [GraphRow] = []
        rows.reserveCapacity(commits.count)
        for commit in commits {
            rows.append(current.advance(past: commit))
        }
        return GraphLayoutPage(rows: rows, state: current)
    }
}

/// The lanes still open after the last laid-out row. Opaque apart from `pendingSegments`; pass it back to
/// `GraphEngine.layout(_:continuing:)` to lay out the next page.
struct GraphLayoutState: Sendable, Equatable {
    /// A lane waiting for `parent` to appear in a later row.
    private struct OpenLane: Sendable, Equatable {
        let parent: ObjectID
        let colorIndex: Int
        /// Set when the lane was opened by the last row's merge node: the line starts at that node's column.
        let origin: Int?
    }

    /// A merge edge from the last row's node (`from`) to an existing lane (`column`).
    private struct PendingJoin: Sendable, Equatable {
        let from: Int
        let column: Int
    }

    static let initial = GraphLayoutState(lanes: [], joins: [])

    /// Indexed by column; `nil` is a free column. Never ends with `nil`.
    private var lanes: [OpenLane?]
    private var joins: [PendingJoin]

    /// Lines leaving the last laid-out row downward, as they would arrive at a next row that none of them ends at. The
    /// renderer draws them below the last loaded row; they are the next row's `incoming` up to the column it converges.
    var pendingSegments: [GraphSegment] {
        incomingSegments(nodeOID: nil, nodeColumn: 0)
    }

    /// Lays out `commit` as the next row and moves the state past it.
    fileprivate mutating func advance(past commit: CommitNode) -> GraphRow {
        let oid = commit.oid
        let waiting = lanes.firstIndex { $0?.parent == oid }
        let column = waiting ?? firstFreeColumn()
        let colorIndex = waiting.flatMap { lanes[$0]?.colorIndex } ?? column % GraphEngine.laneColorCount
        let row = GraphRow(
            oid: oid,
            column: column,
            colorIndex: colorIndex,
            incoming: incomingSegments(nodeOID: oid, nodeColumn: column)
        )
        closeLanes(waitingFor: oid)
        openParentLanes(of: commit, column: column, colorIndex: colorIndex)
        trimFreeColumns()
        return row
    }

    /// Lines from the last row into a row whose node is `nodeOID` at `nodeColumn`: lanes waiting for the node curve
    /// into it, the others pass straight down.
    private func incomingSegments(nodeOID: ObjectID?, nodeColumn: Int) -> [GraphSegment] {
        var segments: [GraphSegment] = []
        segments.reserveCapacity(lanes.count + joins.count)
        for (column, lane) in lanes.enumerated() {
            guard let lane else { continue }
            let to = lane.parent == nodeOID ? nodeColumn : column
            segments.append(GraphSegment(from: lane.origin ?? column, to: to, colorIndex: lane.colorIndex))
        }
        for join in joins {
            guard let lane = lanes[join.column] else { continue }
            let to = lane.parent == nodeOID ? nodeColumn : join.column
            segments.append(GraphSegment(from: join.from, to: to, colorIndex: lane.colorIndex))
        }
        return segments
    }

    /// Ends every lane waiting for `oid` and forgets where the last row's lines came from.
    private mutating func closeLanes(waitingFor oid: ObjectID) {
        for column in lanes.indices {
            guard let lane = lanes[column] else { continue }
            if lane.parent == oid {
                lanes[column] = nil
            } else if lane.origin != nil {
                lanes[column] = OpenLane(parent: lane.parent, colorIndex: lane.colorIndex, origin: nil)
            }
        }
        joins.removeAll(keepingCapacity: true)
    }

    private mutating func openParentLanes(of commit: CommitNode, column: Int, colorIndex: Int) {
        let parents = Self.distinctParents(of: commit)
        guard let first = parents.first else { return }
        place(OpenLane(parent: first, colorIndex: colorIndex, origin: nil), at: column)
        for parent in parents.dropFirst() {
            if let existing = lanes.firstIndex(where: { $0?.parent == parent }) {
                joins.append(PendingJoin(from: column, column: existing))
            } else {
                let free = firstFreeColumn()
                let lane = OpenLane(parent: parent, colorIndex: free % GraphEngine.laneColorCount, origin: column)
                place(lane, at: free)
            }
        }
    }

    /// Parents in order without repeats or the commit itself, which would open lanes that can never close.
    private static func distinctParents(of commit: CommitNode) -> [ObjectID] {
        var seen: Set<ObjectID> = [commit.oid]
        return commit.parents.filter { seen.insert($0).inserted }
    }

    private func firstFreeColumn() -> Int {
        lanes.firstIndex { $0 == nil } ?? lanes.count
    }

    private mutating func place(_ lane: OpenLane, at column: Int) {
        if column == lanes.count {
            lanes.append(lane)
        } else {
            lanes[column] = lane
        }
    }

    private mutating func trimFreeColumns() {
        while let last = lanes.last, last == nil {
            lanes.removeLast()
        }
    }
}
