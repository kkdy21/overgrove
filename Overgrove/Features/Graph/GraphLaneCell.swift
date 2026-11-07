import SwiftUI

/// Geometry of the Graph column (art-direction.md §5.1, §5.3): 20pt lanes after a 7pt inset, rows `size.row-graph`.
enum GraphGeometry {
    static let inset: CGFloat = 7
    static let rowHeight = Tokens.Size.rowGraph
    static let lane = Tokens.Size.graphLaneWidth

    /// Lane count × 20 + 14, at most `size.graph-max-lanes-visible` lanes (wider graphs are clipped for now).
    static func width(lanes: Int) -> CGFloat {
        CGFloat(min(max(lanes, 1), Tokens.Size.graphMaxLanesVisible)) * lane + inset * 2
    }

    static func x(_ column: Int) -> CGFloat {
        inset + lane / 2 + CGFloat(column) * lane
    }

    /// One row-high cubic Bézier between lane centers, control points at 55% from each end (§5.3).
    static func edge(from: Int, to: Int, top: CGFloat) -> Path {
        var path = Path()
        let start = CGPoint(x: x(from), y: top)
        let end = CGPoint(x: x(to), y: top + rowHeight)
        path.move(to: start)
        if from == to {
            path.addLine(to: end)
        } else {
            path.addCurve(
                to: end, control1: CGPoint(x: start.x, y: top + rowHeight * 0.55),
                control2: CGPoint(x: end.x, y: end.y - rowHeight * 0.55))
        }
        return path
    }
}

/// Where the dashed WIP line (WIP node → focused HEAD) crosses a commit row.
enum GraphWipLine: Equatable {
    case none
    /// Passes through the whole row in this column.
    case through(Int)
    /// Ends at this row's node.
    case ends
}

/// The Graph cell of one commit row: half of each line from the row above, half of each line to the row below, the
/// ref connector, and the node (art-direction.md §5.3–§5.4).
struct GraphLaneCell: View {
    let row: GraphRow
    /// Lines from this row to the next (the next row's `incoming`, or the pending ones below the last row).
    let outgoing: [GraphSegment]
    let isMerge: Bool
    let isHead: Bool
    let hasRefs: Bool
    let initials: String
    let avatarIndex: Int
    let wipLine: GraphWipLine
    let width: CGFloat

    @Environment(\.colorSchemeContrast) private var contrast

    private func lane(_ index: Int) -> Color { Tokens.Color.graphLanes[index % Tokens.Color.graphLanes.count] }

    var body: some View {
        Canvas { context, size in
            let center = size.height / 2
            let stroke = StrokeStyle(lineWidth: Tokens.Size.graphEdge, lineCap: .round)
            for segment in row.incoming {
                context.stroke(
                    GraphGeometry.edge(from: segment.from, to: segment.to, top: center - GraphGeometry.rowHeight),
                    with: .color(lane(segment.colorIndex)), style: stroke)
            }
            for segment in outgoing {
                context.stroke(
                    GraphGeometry.edge(from: segment.from, to: segment.to, top: center),
                    with: .color(lane(segment.colorIndex)), style: stroke)
            }
            drawWipLine(&context, center: center)
            let nodeX = GraphGeometry.x(row.column)
            if hasRefs {
                var connector = Path()
                connector.move(to: CGPoint(x: 0, y: center))
                connector.addLine(to: CGPoint(x: nodeX, y: center))
                context.stroke(
                    connector,
                    with: .color(
                        lane(row.colorIndex).opacity(
                            Tokens.refMarkOpacity(contrast, normal: Tokens.Graph.refConnectorOpacity))),
                    style: StrokeStyle(lineWidth: 1.5))
            }
            drawNode(&context, at: CGPoint(x: nodeX, y: center))
        }
        .frame(width: width, height: GraphGeometry.rowHeight)
        .clipped()
        .accessibilityHidden(true)
    }

    private func drawWipLine(_ context: inout GraphicsContext, center: CGFloat) {
        let style = StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 3])
        var path = Path()
        switch wipLine {
        case .none:
            return
        case .through(let column):
            path.move(to: CGPoint(x: GraphGeometry.x(column), y: 0))
            path.addLine(to: CGPoint(x: GraphGeometry.x(column), y: GraphGeometry.rowHeight))
        case .ends:
            path.move(to: CGPoint(x: GraphGeometry.x(row.column), y: 0))
            path.addLine(to: CGPoint(x: GraphGeometry.x(row.column), y: center))
        }
        context.stroke(path, with: .color(Tokens.Color.graphWipNode), style: style)
    }

    private func circle(_ center: CGPoint, diameter: CGFloat) -> Path {
        Path(
            ellipseIn: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        )
    }

    private func drawNode(_ context: inout GraphicsContext, at point: CGPoint) {
        let color = lane(row.colorIndex)
        if isMerge {
            context.fill(
                circle(point, diameter: Tokens.Size.graphNodeMerge + 4), with: .color(Tokens.Color.graphNodeRing))
            context.fill(circle(point, diameter: Tokens.Size.graphNodeMerge), with: .color(color))
            return
        }
        let outer = Tokens.Size.graphNode
        context.fill(circle(point, diameter: outer + 4), with: .color(Tokens.Color.graphNodeRing))
        context.fill(circle(point, diameter: outer), with: .color(color))
        let avatar = outer - Tokens.Size.graphNodeRing * 2
        context.fill(
            circle(point, diameter: avatar),
            with: .color(Tokens.Color.avatars[avatarIndex % Tokens.Color.avatars.count]))
        context.draw(
            Text(initials).font(Tokens.Font.initials).foregroundStyle(Tokens.Color.avatarInitials), at: point)
        if isHead {
            context.stroke(
                circle(point, diameter: Tokens.Size.graphNodeHead), with: .color(Tokens.Color.graphHeadRing),
                style: StrokeStyle(lineWidth: 1.75))
        }
    }
}

/// The WIP row's Graph cell: a dashed hollow node in the focused HEAD's column and the start of the dashed line.
struct GraphWipCell: View {
    let column: Int
    let hasLine: Bool
    let width: CGFloat

    var body: some View {
        Canvas { context, size in
            let point = CGPoint(x: GraphGeometry.x(column), y: size.height / 2)
            let dashed = StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 3])
            if hasLine {
                var line = Path()
                line.move(to: CGPoint(x: point.x, y: point.y + 9))
                line.addLine(to: CGPoint(x: point.x, y: size.height))
                context.stroke(line, with: .color(Tokens.Color.graphWipNode), style: dashed)
            }
            let node = Path(ellipseIn: CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18))
            context.stroke(node, with: .color(Tokens.Color.graphWipNode), style: dashed)
            context.draw(
                Text(Image(systemName: "pencil")).font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Tokens.Color.graphWipNode), at: point)
        }
        .frame(width: width, height: GraphGeometry.rowHeight)
        .accessibilityHidden(true)
    }
}
