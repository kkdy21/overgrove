import SwiftUI

/// Geometry of the Graph column (art-direction.md §5.1, §5.3): 20pt lanes after a 7pt inset, rows `size.row-graph`,
/// all times the graph zoom (#121). `standard` is 100 %.
struct GraphGeometry: Equatable, Sendable {
    static let standard = GraphZoom.actualSize.geometry

    let scale: CGFloat
    let rowHeight: CGFloat

    var inset: CGFloat { 7 * scale }
    var lane: CGFloat { Tokens.Size.graphLaneWidth * scale }
    var edgeWidth: CGFloat { Tokens.Size.graphEdge * scale }
    var node: CGFloat { Tokens.Size.graphNode * scale }
    var nodeMerge: CGFloat { Tokens.Size.graphNodeMerge * scale }
    var nodeHead: CGFloat { Tokens.Size.graphNodeHead * scale }
    var nodeRing: CGFloat { Tokens.Size.graphNodeRing * scale }

    /// The Graph column as drawn: lane count × lane + 2 insets, at most `size.graph-max-lanes-visible` lanes. Wider
    /// graphs scroll sideways inside it (interaction.md §2.1, #255).
    func width(lanes: Int) -> CGFloat {
        CGFloat(min(max(lanes, 1), Tokens.Size.graphMaxLanesVisible)) * lane + inset * 2
    }

    /// Every lane: what the column would need to show them all.
    func contentWidth(lanes: Int) -> CGFloat {
        CGFloat(max(lanes, 1)) * lane + inset * 2
    }

    /// How far the lanes can scroll sideways: 0 up to `size.graph-max-lanes-visible` lanes.
    func maxOffset(lanes: Int) -> CGFloat {
        contentWidth(lanes: lanes) - width(lanes: lanes)
    }

    func clampOffset(_ offset: CGFloat, lanes: Int) -> CGFloat {
        guard offset.isFinite else { return 0 }
        return min(max(offset, 0), maxOffset(lanes: lanes))
    }

    /// The offset that brings `column`'s node fully into view, moving as little as possible (the selection moved
    /// to a commit in a lane scrolled out of sight).
    func revealing(_ column: Int, offset: CGFloat, lanes: Int) -> CGFloat {
        let visible = width(lanes: lanes)
        let left = x(column) - lane / 2 - inset
        let right = x(column) + lane / 2 + inset
        var next = clampOffset(offset, lanes: lanes)
        if left < next {
            next = left
        } else if right > next + visible {
            next = right - visible
        }
        return clampOffset(next, lanes: lanes)
    }

    func x(_ column: Int) -> CGFloat {
        inset + lane / 2 + CGFloat(column) * lane
    }

    /// One row-high cubic Bézier between lane centers, control points at 55% from each end (§5.3).
    func edge(from: Int, to: Int, top: CGFloat) -> Path {
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
    /// How far the lanes are scrolled sideways (#255); the cell shows `offset ..< offset + width`.
    var offset: CGFloat = 0

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.graphZoom) private var zoom

    private var geometry: GraphGeometry { zoom.geometry }

    private func lane(_ index: Int) -> Color { Tokens.Color.graphLanes[index % Tokens.Color.graphLanes.count] }

    var body: some View {
        Canvas { context, size in
            context.translateBy(x: -offset, y: 0)
            let center = size.height / 2
            let stroke = StrokeStyle(lineWidth: geometry.edgeWidth, lineCap: .round)
            for segment in row.incoming {
                context.stroke(
                    geometry.edge(from: segment.from, to: segment.to, top: center - geometry.rowHeight),
                    with: .color(lane(segment.colorIndex)), style: stroke)
            }
            for segment in outgoing {
                context.stroke(
                    geometry.edge(from: segment.from, to: segment.to, top: center),
                    with: .color(lane(segment.colorIndex)), style: stroke)
            }
            drawWipLine(&context, center: center)
            let nodeX = geometry.x(row.column)
            if hasRefs && nodeX > offset {
                var connector = Path()
                connector.move(to: CGPoint(x: offset, y: center))
                connector.addLine(to: CGPoint(x: nodeX, y: center))
                context.stroke(
                    connector,
                    with: .color(
                        lane(row.colorIndex).opacity(
                            Tokens.refMarkOpacity(contrast, normal: Tokens.Graph.refConnectorOpacity))),
                    style: StrokeStyle(lineWidth: 1.5 * geometry.scale))
            }
            drawNode(&context, at: CGPoint(x: nodeX, y: center))
        }
        .frame(width: width, height: geometry.rowHeight)
        .clipped()
        .accessibilityHidden(true)
    }

    private func drawWipLine(_ context: inout GraphicsContext, center: CGFloat) {
        let style = StrokeStyle(
            lineWidth: 1.5 * geometry.scale, lineCap: .round, dash: [3 * geometry.scale, 3 * geometry.scale])
        var path = Path()
        switch wipLine {
        case .none:
            return
        case .through(let column):
            path.move(to: CGPoint(x: geometry.x(column), y: 0))
            path.addLine(to: CGPoint(x: geometry.x(column), y: geometry.rowHeight))
        case .ends:
            path.move(to: CGPoint(x: geometry.x(row.column), y: 0))
            path.addLine(to: CGPoint(x: geometry.x(row.column), y: center))
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
                circle(point, diameter: geometry.nodeMerge + 4 * geometry.scale),
                with: .color(Tokens.Color.graphNodeRing))
            context.fill(circle(point, diameter: geometry.nodeMerge), with: .color(color))
            return
        }
        let outer = geometry.node
        context.fill(circle(point, diameter: outer + 4 * geometry.scale), with: .color(Tokens.Color.graphNodeRing))
        context.fill(circle(point, diameter: outer), with: .color(color))
        let avatar = outer - geometry.nodeRing * 2
        context.fill(
            circle(point, diameter: avatar),
            with: .color(Tokens.Color.avatars[avatarIndex % Tokens.Color.avatars.count]))
        context.draw(
            Text(initials).font(zoom.typography.initials).foregroundStyle(Tokens.Color.avatarInitials), at: point)
        if isHead {
            context.stroke(
                circle(point, diameter: geometry.nodeHead), with: .color(Tokens.Color.graphHeadRing),
                style: StrokeStyle(lineWidth: 1.75 * geometry.scale))
        }
    }
}

/// The WIP row's Graph cell: a dashed hollow node in the focused HEAD's column and the start of the dashed line.
struct GraphWipCell: View {
    let column: Int
    let hasLine: Bool
    let width: CGFloat
    var offset: CGFloat = 0

    @Environment(\.graphZoom) private var zoom

    var body: some View {
        let geometry = zoom.geometry
        let scale = geometry.scale
        return
            Canvas { context, size in
                context.translateBy(x: -offset, y: 0)
                let point = CGPoint(x: geometry.x(column), y: size.height / 2)
                let dashed = StrokeStyle(lineWidth: 1.5 * scale, lineCap: .round, dash: [3 * scale, 3 * scale])
                if hasLine {
                    var line = Path()
                    line.move(to: CGPoint(x: point.x, y: point.y + 9 * scale))
                    line.addLine(to: CGPoint(x: point.x, y: size.height))
                    context.stroke(line, with: .color(Tokens.Color.graphWipNode), style: dashed)
                }
                let node = Path(
                    ellipseIn: CGRect(
                        x: point.x - 9 * scale, y: point.y - 9 * scale, width: 18 * scale, height: 18 * scale))
                context.stroke(node, with: .color(Tokens.Color.graphWipNode), style: dashed)
                context.draw(
                    Text(Image(systemName: "pencil")).font(zoom.typography.points(8, weight: .semibold))
                        .foregroundStyle(Tokens.Color.graphWipNode), at: point)
            }
            .frame(width: width, height: geometry.rowHeight)
            .clipped()
            .accessibilityHidden(true)
    }
}
