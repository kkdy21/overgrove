import AppKit
import SwiftUI

// MARK: - Author filter chips

/// The graph panel header's chip row (screens.md S-01, #255): `All`, up to five author chips, a `+n` menu for the
/// rest, then `AI-assisted`. A picked chip is filled with the accent.
struct GraphAuthorFilterBar: View {
    let summary: GraphAuthorSummary
    let selection: GraphAuthorSelection
    let onSelect: (GraphAuthorSelection) -> Void

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Image(systemName: "person.2").foregroundStyle(Tokens.Color.textSecondary).accessibilityHidden(true)
            GraphFilterChip(isSelected: selection == .all, accessibilityLabel: "All authors") {
                onSelect(.all)
            } label: {
                Text("All")
            }
            ForEach(summary.visibleChips) { chip in
                authorChip(chip)
            }
            if !summary.overflowChips.isEmpty {
                overflowMenu
            }
            if summary.aiAssistedCount > 0 {
                Tokens.Color.borderStrong.frame(width: 1, height: 14).padding(.horizontal, Tokens.Spacing.xxs)
                    .accessibilityHidden(true)
                GraphFilterChip(
                    isSelected: selection == .aiAssisted,
                    accessibilityLabel: GraphAuthorSummary.accessibilityLabel(
                        name: "AI-assisted", count: summary.aiAssistedCount)
                ) {
                    onSelect(.aiAssisted)
                } label: {
                    Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold))
                    Text("AI-assisted")
                    count(summary.aiAssistedCount, isSelected: selection == .aiAssisted)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter commits by author")
    }

    private func authorChip(_ chip: GraphAuthorChip) -> some View {
        let isSelected = selection == .author(chip.key)
        return GraphFilterChip(
            isSelected: isSelected,
            accessibilityLabel: GraphAuthorSummary.accessibilityLabel(name: chip.name, count: chip.count)
        ) {
            onSelect(.author(chip.key))
        } label: {
            GraphChipAvatar(initials: chip.initials, avatarIndex: chip.avatarIndex)
            Text(chip.name).lineLimit(1).truncationMode(.tail).frame(maxWidth: Self.nameMaxWidth, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            count(chip.count, isSelected: isSelected)
        }
        .help(chip.name)
    }

    /// The authors past the fifth (screens.md S-01). Picking one of them fills the `+n` chip.
    private var overflowMenu: some View {
        let isSelected = summary.overflowChips.contains { selection == .author($0.key) }
        return Menu {
            ForEach(summary.overflowChips) { chip in
                Toggle(
                    "\(chip.name) (\(chip.count.formatted()))",
                    isOn: Binding(get: { selection == .author(chip.key) }, set: { _ in onSelect(.author(chip.key)) }))
            }
        } label: {
            Text("+\(summary.overflowChips.count)")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(GraphChipButtonStyle(isSelected: isSelected))
        .fixedSize()
        .help("More authors")
        .accessibilityLabel("\(summary.overflowChips.count) more authors")
    }

    private func count(_ value: Int, isSelected: Bool) -> some View {
        Text(value.formatted())
            .foregroundStyle(isSelected ? Tokens.Color.textOnAccent : Tokens.Color.textSecondary)
            .monospacedDigit()
    }

    /// Long names are cut so five chips still fit the header.
    static let nameMaxWidth: CGFloat = 120
}

/// A capsule chip: `surface.control` normally, the accent with `text.on-accent` when picked.
struct GraphFilterChip<Label: View>: View {
    let isSelected: Bool
    let accessibilityLabel: String
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Spacing.xs) { label }
        }
        .buttonStyle(GraphChipButtonStyle(isSelected: isSelected))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct GraphChipButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Tokens.Font.pill)
            .foregroundStyle(isSelected ? Tokens.Color.textOnAccent : Tokens.Color.textPrimary)
            .padding(.horizontal, Tokens.Spacing.sm)
            .frame(height: Self.height)
            .background(Capsule().fill(isSelected ? Tokens.Color.accent : Tokens.Color.surfaceControl))
            // No outline normally; `border.strong` 1.5pt under Increase Contrast (#304).
            .controlOutline(Capsule(), normal: nil)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }

    /// Fits the 40pt panel header with the ref pill's rhythm. No token for chip height.
    static let height: CGFloat = 24
}

/// The 16pt initials avatar used outside graph nodes (screens.md "작성자 표현").
struct GraphChipAvatar: View {
    let initials: String
    let avatarIndex: Int

    var body: some View {
        Circle()
            .fill(Tokens.Color.avatars[avatarIndex % Tokens.Color.avatars.count])
            .frame(width: 16, height: 16)
            .overlay {
                Text(initials).font(.system(size: 7.5, weight: .bold)).foregroundStyle(Tokens.Color.avatarInitials)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Column menu

/// `⋯` at the right of the graph panel header: show or hide Author, Date, and SHA (art-direction.md §5.1).
struct GraphColumnMenu: View {
    let columns: GraphColumnLayout
    let onChange: (GraphColumnLayout) -> Void
    /// `Show Stashes` (#384): stash rows above their base commits.
    var showsStashes = true
    var onSetShowsStashes: ((Bool) -> Void)?

    var body: some View {
        Menu {
            if let onSetShowsStashes {
                Toggle("Show Stashes", isOn: Binding(get: { showsStashes }, set: onSetShowsStashes))
                Divider()
            }
            Section("Columns") {
                ForEach(GraphColumnLayout.Column.allCases.filter(\.isHideable), id: \.self) { column in
                    Toggle(
                        column.title,
                        isOn: Binding(
                            get: { columns.isVisible(column) }, set: { _ in onChange(columns.toggling(column)) }))
                }
            }
            Divider()
            Button("Reset Column Widths") {
                var reset = GraphColumnLayout.default
                for column in GraphColumnLayout.Column.allCases where !columns.isVisible(column) {
                    reset = reset.toggling(column)
                }
                onChange(reset)
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Columns")
        .accessibilityLabel("Graph columns")
    }
}

// MARK: - Column header

/// Refs | Graph | Message | Author | Date | SHA (art-direction.md §5.1). The separators next to Refs, Author, Date,
/// and SHA are drag handles; double-click fits the column to the loaded rows (interaction.md §2.1). When the graph
/// is wider than its column, a thin scroller under the Graph title moves the lanes.
struct GraphColumnHeader: View {
    let columns: GraphColumnLayout
    let graphWidth: CGFloat
    var laneScroll: GraphLaneScroll = .none
    var onResize: (GraphColumnLayout.Column, CGFloat) -> Void = { _, _ in }
    var onResizeEnded: () -> Void = {}
    var onFit: (GraphColumnLayout.Column) -> Void = { _ in }
    var onStep: (GraphColumnLayout.Column, CGFloat) -> Void = { _, _ in }
    var onScrollLanes: (CGFloat) -> Void = { _ in }

    /// Column widths are stored at 100 % and drawn at the graph zoom (#121).
    @Environment(\.graphZoom) private var zoom

    var body: some View {
        HStack(spacing: 0) {
            title("Refs").frame(width: columns.width(of: .refs) * zoom.scale, alignment: .leading)
                .overlay(alignment: .trailing) { divider(.refs, widensRight: true).offset(x: Self.handleWidth / 2) }
            title("Graph").frame(width: graphWidth, alignment: .leading)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    if laneScroll.maxOffset > 0 {
                        GraphLaneScroller(scroll: laneScroll, width: graphWidth, onScroll: onScrollLanes)
                    }
                }
                .overlay(alignment: .trailing) { separator.offset(x: 0.5) }
            title("Message").frame(maxWidth: .infinity, alignment: .leading)
            ForEach(columns.trailingColumns, id: \.self) { column in
                title(column.title).frame(width: columns.width(of: column) * zoom.scale, alignment: .leading)
                    .overlay(alignment: .leading) {
                        divider(column, widensRight: false).offset(x: -Self.handleWidth / 2)
                    }
            }
        }
        .frame(height: Tokens.Size.columnHeader)
        .background(Tokens.Color.surfacePanelHeader)
    }

    /// The 8pt hit area around each separator, as wide as a panel gutter.
    static let handleWidth = PanelLayout.gap

    private var separator: some View {
        Tokens.Color.borderStrong.frame(width: 1, height: 12).accessibilityHidden(true)
    }

    private func divider(_ column: GraphColumnLayout.Column, widensRight: Bool) -> some View {
        GraphColumnDivider(
            column: column, width: columns.width(of: column), limitState: columns.limitState(of: column),
            widensRight: widensRight,
            onDrag: { onResize(column, (widensRight ? $0 : -$0) / zoom.scale) }, onDragEnded: onResizeEnded,
            onFit: { onFit(column) }, onStep: { onStep(column, $0) })
    }

    private func title(_ text: String) -> some View {
        Text(text).font(Tokens.Font.columnHeader).foregroundStyle(Tokens.Color.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, Tokens.Spacing.sm)
    }
}

/// One column separator: a 1×12 `border.strong` line in an 8pt-wide handle. It follows the pointer without
/// animation and shows the one-way cursor at a limit, like the panel dividers (interaction.md §2.1).
private struct GraphColumnDivider: View {
    let column: GraphColumnLayout.Column
    let width: CGFloat
    let limitState: PanelLayout.LimitState
    /// Refs widens when dragged right; the columns right of Message widen when dragged left.
    let widensRight: Bool
    /// The drag's horizontal translation since it began.
    let onDrag: (CGFloat) -> Void
    let onDragEnded: () -> Void
    let onFit: () -> Void
    /// ±8pt from the keyboard or VoiceOver; positive widens.
    let onStep: (CGFloat) -> Void

    @State private var isHovering = false
    @GestureState private var isDragging = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(isHovering || isDragging ? Tokens.Color.accent : Tokens.Color.borderStrong)
                .frame(width: 1, height: 12)
        }
        .frame(width: GraphColumnHeader.handleWidth, height: Tokens.Size.columnHeader)
        .contentShape(Rectangle())
        .background(CursorArea(cursor: cursor))
        .onHover { isHovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .updating($isDragging) { _, active, _ in active = true }
                .onChanged { onDrag($0.translation.width) }
                .onEnded { _ in onDragEnded() }
        )
        .onChange(of: isDragging) { _, active in
            // A cancelled drag never calls `onEnded`; this keeps the last width.
            if !active { onDragEnded() }
        }
        .onTapGesture(count: 2, perform: onFit)
        .focusable(interactions: .activate)
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .shift, .option]) else { return .ignored }
            let right = press.key == .rightArrow
            onStep(right == widensRight ? GraphColumnLayout.keyboardStep : -GraphColumnLayout.keyboardStep)
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel(column.accessibilityLabel)
        .accessibilityValue("\(Int(width.rounded())) points")
        .accessibilityHint("Double-click to fit the column to its contents")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onStep(GraphColumnLayout.keyboardStep)
            case .decrement: onStep(-GraphColumnLayout.keyboardStep)
            @unknown default: break
            }
        }
    }

    private var cursor: NSCursor {
        switch limitState {
        case .between: .resizeLeftRight
        case .atMinimum: widensRight ? .resizeRight : .resizeLeft
        case .atMaximum: widensRight ? .resizeLeft : .resizeRight
        }
    }
}

// MARK: - Wide lanes

/// Where the lanes are scrolled to when there are more than `size.graph-max-lanes-visible` (#255).
struct GraphLaneScroll: Equatable {
    let offset: CGFloat
    let maxOffset: CGFloat
    let contentWidth: CGFloat

    static let none = GraphLaneScroll(offset: 0, maxOffset: 0, contentWidth: 0)

    init(offset: CGFloat, maxOffset: CGFloat, contentWidth: CGFloat) {
        self.offset = offset
        self.maxOffset = maxOffset
        self.contentWidth = contentWidth
    }

    init(offset: CGFloat, lanes: Int, geometry: GraphGeometry = .standard) {
        self.init(
            offset: geometry.clampOffset(offset, lanes: lanes), maxOffset: geometry.maxOffset(lanes: lanes),
            contentWidth: geometry.contentWidth(lanes: lanes))
    }
}

/// A thin overlay scroller at the bottom of the Graph column title (`surface.scrollbar-thumb`, 5pt as the system
/// overlay scrollers). Dragging the thumb moves the lanes; VoiceOver adjusts it a lane at a time.
private struct GraphLaneScroller: View {
    let scroll: GraphLaneScroll
    let width: CGFloat
    let onScroll: (CGFloat) -> Void

    @State private var dragStart: CGFloat?
    @Environment(\.graphZoom) private var zoom

    private var track: CGFloat { max(width - Tokens.Spacing.sm * 2, 1) }
    private var thumb: CGFloat { max(track * width / max(scroll.contentWidth, 1), 16) }
    private var thumbX: CGFloat {
        scroll.maxOffset > 0 ? (track - thumb) * scroll.offset / scroll.maxOffset : 0
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Tokens.Color.surfaceScrollbarThumb.opacity(0.35)).frame(width: track, height: 3)
            Capsule().fill(Tokens.Color.surfaceScrollbarThumb).frame(width: thumb, height: 5)
                .offset(x: thumbX)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let start = dragStart ?? scroll.offset
                            if dragStart == nil { dragStart = start }
                            let perPoint = scroll.maxOffset / max(track - thumb, 1)
                            onScroll(start + value.translation.width * perPoint)
                        }
                        .onEnded { _ in dragStart = nil }
                )
        }
        .frame(width: track, height: 6)
        .padding(.bottom, 2)
        .accessibilityElement()
        .accessibilityLabel("Graph lanes")
        .accessibilityValue("Scrolled \(Int(scroll.offset.rounded())) of \(Int(scroll.maxOffset.rounded())) points")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onScroll(scroll.offset + zoom.geometry.lane)
            case .decrement: onScroll(scroll.offset - zoom.geometry.lane)
            @unknown default: break
            }
        }
    }
}

/// Sideways scrolling over the Graph column (trackpad swipe, or ⇧ + mouse wheel). The rows' vertical scroll view
/// would take every wheel event, so a local event monitor picks out the horizontal ones that land on this view's
/// area; vertical ones pass through untouched. It takes no mouse events itself (`hitTest` returns nil).
struct GraphLaneScrollMonitor: NSViewRepresentable {
    var isEnabled: Bool
    /// One lane in points: a line of a line-based wheel (the graph zoom's lane width, #121).
    var lane: CGFloat = GraphGeometry.standard.lane
    /// Points to move the lanes by; positive scrolls toward later lanes.
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> MonitorView {
        MonitorView()
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.isEnabled = isEnabled
        view.lane = lane
        view.onScroll = onScroll
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stop()
    }

    final class MonitorView: NSView {
        var isEnabled = false
        var lane = GraphGeometry.standard.lane
        var onScroll: (CGFloat) -> Void = { _ in }
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                // Local monitors run on the main thread.
                let consumed = MainActor.assumeIsolated { self?.consume(event) ?? false }
                return consumed ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func consume(_ event: NSEvent) -> Bool {
            guard isEnabled, event.window === window, !isHiddenOrHasHiddenAncestor,
                bounds.contains(convert(event.locationInWindow, from: nil))
            else { return false }
            let horizontal = event.scrollingDeltaX
            guard horizontal != 0, abs(horizontal) > abs(event.scrollingDeltaY) else { return false }
            // Line-based wheels report lines; a line is one lane.
            let scale = event.hasPreciseScrollingDeltas ? 1 : lane
            onScroll(-horizontal * scale)
            return true
        }
    }
}

// MARK: - Fit to content

/// The widest content of a column over the loaded rows, for double-click on its divider (interaction.md §2.1).
/// Measured with the fonts the cells use; at most `rowLimit` rows are looked at so a long history stays quick.
@MainActor
enum GraphColumnFit {
    static let rowLimit = 2_000

    static func contentWidths(
        _ column: GraphColumnLayout.Column, commits: ArraySlice<CommitNode>, pills: [ObjectID: [GraphRefPill]],
        now: Date
    ) -> [CGFloat] {
        let rows = commits.prefix(rowLimit)
        switch column {
        case .author:
            let font = NSFont.preferredFont(forTextStyle: .callout)
            return Set(rows.map { PathValidator.displayable($0.authorName) }).map { measure($0, font) }
        case .date:
            let font = NSFont.preferredFont(forTextStyle: .callout)
            return Set(rows.map { GraphCommitText.compact($0.authorDate, now: now) }).map { measure($0, font) }
        case .sha:
            let size = NSFont.preferredFont(forTextStyle: .subheadline).pointSize
            let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            return rows.first.map { [measure($0.oid.short, font)] } ?? []
        case .refs:
            let font = NSFont.systemFont(ofSize: 11, weight: .medium)
            let caption = NSFont.preferredFont(forTextStyle: .caption1)
            return rows.compactMap { commit -> CGFloat? in
                guard let list = pills[commit.oid], let first = list.first else { return nil }
                // Pill: 6pt padding each side, a 9pt symbol + 3pt gap when it has one, the trailing `network`.
                var width = measure(first.title, font) + 12
                if first.kind != .localBranch { width += 12 }
                if first.hasMatchingRemote { width += 12 }
                if list.count > 1 { width += Tokens.Spacing.xs + measure("+\(list.count - 1)", caption) }
                return width
            }
        }
    }

    private static func measure(_ text: String, _ font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}
