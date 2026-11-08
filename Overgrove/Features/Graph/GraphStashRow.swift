import SwiftUI

/// Stashes in the commit graph (#384, ADR-0010 §5 as amended, information-architecture.md §3.2).
///
/// Like the WIP row, a stash is a virtual row outside `GraphEngine`: it sits right above its base commit (the stash's
/// first parent) and does not change the lanes or the pages. Its index and untracked-files parents are not drawn.
enum GraphStashPlacement {
    /// The stashes whose base commit is a loaded row, by that row's index, each list in `stash@{n}` order (the
    /// newest on top). A stash whose base is on a page not loaded yet appears once that page loads; one whose base
    /// is outside the graph (not reachable from a branch, a tag, or a worktree HEAD) stays in the sidebar only.
    static func byBaseRow(_ stashes: [Stash], index: (ObjectID) -> Int?) -> [Int: [Stash]] {
        var rows: [Int: [Stash]] = [:]
        for stash in stashes.sorted(by: { $0.index < $1.index }) {
            guard let base = stash.baseCommit, let row = index(base) else { continue }
            rows[row, default: []].append(stash)
        }
        return rows
    }
}

/// What a stash row shows.
struct GraphStashText: Equatable {
    let refName: String
    let message: String
    let date: String
    let absoluteDate: String
    let shortSHA: String
    let accessibilityLabel: String

    init(_ stash: Stash, now: Date) {
        refName = stash.refName
        // Repository text: control characters are made visible, as for commit subjects.
        message = PathValidator.displayable(stash.message)
        date = GraphCommitText.compact(stash.date, now: now)
        absoluteDate = GraphCommitText.absolute(stash.date)
        shortSHA = stash.oid.short
        let base = stash.baseCommit.map { ", made on \($0.short)" } ?? ""
        accessibilityLabel = "Stash \(stash.refName): \(message)\(base), \(date)"
    }
}

/// The Graph cell of a stash row: the lanes passing between the commit above and the base commit, a hollow square
/// in the base commit's lane colour, and a dashed line down to the base commit (to the next stash when several share
/// the base).
struct GraphStashCell: View {
    /// The base commit's column and lane colour.
    let column: Int
    let colorIndex: Int
    /// The lines from the commit row above to the base commit (the base row's `incoming`), drawn straight through.
    let through: [GraphSegment]
    /// The dashed WIP line passes through this row in that column.
    let wipColumn: Int?
    /// Another stash of the same base is above this one, so the dashed line comes in from the top.
    let hasStashAbove: Bool
    let width: CGFloat
    var offset: CGFloat = 0

    @Environment(\.graphZoom) private var zoom

    private func lane(_ index: Int) -> Color { Tokens.Color.graphLanes[index % Tokens.Color.graphLanes.count] }

    var body: some View {
        let geometry = zoom.geometry
        let scale = geometry.scale
        return Canvas { context, size in
            context.translateBy(x: -offset, y: 0)
            let solid = StrokeStyle(lineWidth: geometry.edgeWidth, lineCap: .butt)
            for segment in through {
                // A row-high Bézier crosses the row boundary at the midpoint of its two lanes (t = 0.5).
                let x = (geometry.x(segment.from) + geometry.x(segment.to)) / 2
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(lane(segment.colorIndex)), style: solid)
            }
            let dashed = StrokeStyle(lineWidth: 1.5 * scale, lineCap: .round, dash: [3 * scale, 3 * scale])
            if let wipColumn {
                var line = Path()
                line.move(to: CGPoint(x: geometry.x(wipColumn), y: 0))
                line.addLine(to: CGPoint(x: geometry.x(wipColumn), y: size.height))
                context.stroke(line, with: .color(Tokens.Color.graphWipNode), style: dashed)
            }
            let center = CGPoint(x: geometry.x(column), y: size.height / 2)
            let side = geometry.node * 0.7
            var connector = Path()
            if hasStashAbove {
                connector.move(to: CGPoint(x: center.x, y: 0))
                connector.addLine(to: CGPoint(x: center.x, y: center.y - side / 2))
            }
            connector.move(to: CGPoint(x: center.x, y: center.y + side / 2))
            connector.addLine(to: CGPoint(x: center.x, y: size.height))
            context.stroke(connector, with: .color(lane(colorIndex)), style: dashed)
            let square = Path(
                roundedRect: CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side),
                cornerRadius: 3 * scale)
            context.fill(square, with: .color(Tokens.Color.surfaceCanvas))
            context.stroke(square, with: .color(lane(colorIndex)), style: StrokeStyle(lineWidth: 2 * scale))
        }
        .frame(width: width, height: geometry.rowHeight)
        .clipped()
        .accessibilityHidden(true)
    }
}

/// A stash row (screens.md S-01): a `stash@{n}` pill, the stash node, the message, and its date and SHA. Clicking it
/// selects the stash, as in the sidebar (S-04).
struct GraphStashRowView: View {
    let stash: Stash
    let column: Int
    let colorIndex: Int
    let through: [GraphSegment]
    let wipColumn: Int?
    let hasStashAbove: Bool
    let isSelected: Bool
    let graphWidth: CGFloat
    let now: Date
    var columns: GraphColumnLayout = .default
    var laneOffset: CGFloat = 0
    let onSelect: () -> Void

    @Environment(\.graphZoom) private var zoom

    private var lane: Color { Tokens.Color.graphLanes[colorIndex % Tokens.Color.graphLanes.count] }

    var body: some View {
        let text = GraphStashText(stash, now: now)
        HStack(spacing: 0) {
            HStack(spacing: 3) {
                Image(systemName: "tray").font(zoom.typography.points(9, weight: .semibold))
                Text(text.refName).lineLimit(1)
            }
            .font(zoom.typography.points(11, weight: .medium))
            .foregroundStyle(Tokens.Color.textSecondary)
            .padding(.horizontal, 6)
            .frame(height: Tokens.Size.refPillHeight * zoom.scale)
            .overlay {
                RoundedRectangle(cornerRadius: 5).strokeBorder(lane.opacity(0.6), lineWidth: 1)
            }
            .padding(.horizontal, Tokens.Spacing.xs)
            .frame(width: columns.width(of: .refs) * zoom.scale, alignment: .trailing)
            .clipped()
            GraphStashCell(
                column: column, colorIndex: colorIndex, through: through, wipColumn: wipColumn,
                hasStashAbove: hasStashAbove, width: graphWidth, offset: laneOffset)
            Text(text.message).font(zoom.typography.body).foregroundStyle(Tokens.Color.textSecondary).lineLimit(1)
                .padding(.horizontal, Tokens.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
            if columns.isVisible(.author) {
                Color.clear.frame(width: columns.width(of: .author) * zoom.scale)
            }
            if columns.isVisible(.date) {
                cell(text.date, width: columns.width(of: .date)).help(text.absoluteDate)
            }
            if columns.isVisible(.sha) {
                cell(text.shortSHA, width: columns.width(of: .sha), font: zoom.typography.monoSmall)
            }
        }
        .frame(height: zoom.geometry.rowHeight)
        .background(isSelected ? lane.opacity(0.16) : Color.clear)
        .overlay(alignment: .leading) {
            if isSelected { Rectangle().fill(lane).frame(width: 3) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.accessibilityLabel)
        .accessibilityHint("Shows the stash's changes")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onSelect() }
    }

    private func cell(_ value: String, width: CGFloat, font: Font? = nil) -> some View {
        Text(value).font(font ?? zoom.typography.callout)
            .foregroundStyle(isSelected ? Tokens.Color.textSecondary : Tokens.Color.textTertiary).lineLimit(1)
            .padding(.horizontal, Tokens.Spacing.sm)
            .frame(width: width * zoom.scale, alignment: .leading)
    }
}
