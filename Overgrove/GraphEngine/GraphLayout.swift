// Output of `GraphEngine`: what the graph column draws for each commit row (ADR-0010 §2).
//
// Coordinates are lane columns (0 is leftmost) and row positions; the renderer turns them into points with
// `size.graph-lane-width` and the row height. Lines join row centers: a segment runs from the node center height of the
// row above to the node center height of its own row, so the renderer draws its lower half in the row above and its
// upper half in this row.

/// One line between the center of the row above and the center of this row.
///
/// - `from == to`: a lane passing straight down (or the node's own lane continuing).
/// - `to` is the node column and `from` is not: a branch edge, a lane that ends by curving into its parent. Its color is
///   the ending (child) lane's color.
/// - `from` is the node column of the row above and `to` is not: a merge edge leaving a merge node for the lane of a
///   second or later parent. Its color is that parent lane's color.
struct GraphSegment: Sendable, Hashable {
    /// Column in the row above.
    let from: Int
    /// Column in this row.
    let to: Int
    /// Lane color, `graph.lane.<colorIndex>` (0–7).
    let colorIndex: Int
}

/// The layout of one commit row.
struct GraphRow: Sendable, Hashable {
    let oid: ObjectID
    /// Column of the commit node.
    let column: Int
    /// Color of the node's lane (0–7). It is the column where the lane started, mod 8, and never changes (ADR-0010 §4).
    let colorIndex: Int
    /// Lines arriving from the row above: open lanes in column order, then merge edges from the node above in parent
    /// order. Empty for the first row of a history. The lines below this row are the next row's `incoming`, or
    /// `GraphLayoutState.pendingSegments` for the last row laid out so far.
    let incoming: [GraphSegment]
}

/// The rows for one page of commits and the state to continue from on the next page.
struct GraphLayoutPage: Sendable, Equatable {
    let rows: [GraphRow]
    let state: GraphLayoutState
}
