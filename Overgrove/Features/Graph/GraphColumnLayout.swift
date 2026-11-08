import CoreGraphics
import Foundation

/// Widths and visibility of the graph's columns (art-direction.md §5.1, interaction.md §2.1, #255).
///
/// A pure value type like `PanelLayout`: the header's dividers and the `⋯` menu change it, and `PanelLayoutStore`
/// remembers it per repository. Graph follows the lane count and Message takes the rest, so neither is stored.
struct GraphColumnLayout: Codable, Equatable, Sendable {
    /// The columns with a width of their own.
    enum Column: String, Codable, CaseIterable, Sendable {
        case refs
        case author
        case date
        case sha

        var title: String {
            switch self {
            case .refs: String(localized: "Refs", comment: "Graph column")
            case .author: String(localized: "Author", comment: "Graph column")
            case .date: String(localized: "Date", comment: "Graph column")
            case .sha: String(localized: "SHA", comment: "Graph column")
            }
        }

        /// Refs, Graph, and Message cannot be hidden (art-direction.md §5.1).
        var isHideable: Bool { self != .refs }

        /// tokens.json `size.column-*-ideal`; the ranges are in each token's description and art-direction.md §5.1.
        var limits: PanelLayout.Limits {
            switch self {
            case .refs: PanelLayout.Limits(minimum: 96, ideal: Tokens.Size.columnRefsIdeal, maximum: 280)
            case .author: PanelLayout.Limits(minimum: 72, ideal: Tokens.Size.columnAuthorIdeal, maximum: 200)
            case .date: PanelLayout.Limits(minimum: 44, ideal: Tokens.Size.columnDateIdeal, maximum: 120)
            case .sha: PanelLayout.Limits(minimum: 64, ideal: Tokens.Size.columnShaIdeal, maximum: 96)
            }
        }

        /// `Author column width, 108 points` (the divider's VoiceOver label and value).
        var accessibilityLabel: String { "\(title) column width" }
    }

    /// Message keeps at least this much (art-direction.md §5.1).
    static let messageMinimum: CGFloat = 200
    /// `←` / `→` on a focused divider, as for the panel dividers (interaction.md §2.1: 8pt).
    static let keyboardStep = Tokens.Spacing.sm

    static let `default` = GraphColumnLayout()

    private(set) var widths: [Column: CGFloat]
    private(set) var hidden: Set<Column>

    init(widths: [Column: CGFloat] = [:], hidden: Set<Column> = []) {
        self.widths = widths
        self.hidden = hidden
        self = sanitized()
    }

    func width(of column: Column) -> CGFloat {
        widths[column] ?? column.limits.ideal
    }

    func isVisible(_ column: Column) -> Bool {
        !hidden.contains(column)
    }

    /// The width as drawn: 0 when hidden.
    func drawnWidth(of column: Column) -> CGFloat {
        isVisible(column) ? width(of: column) : 0
    }

    /// The visible columns right of Message, in order.
    var trailingColumns: [Column] {
        [.author, .date, .sha].filter(isVisible)
    }

    func setting(_ column: Column, to width: CGFloat) -> GraphColumnLayout {
        var copy = self
        copy.widths[column] = Self.clamp(width, column.limits)
        return copy
    }

    func resizing(_ column: Column, by delta: CGFloat) -> GraphColumnLayout {
        setting(column, to: width(of: column) + delta)
    }

    /// Refs, Graph, and the visible columns right of Message: everything but Message.
    func fixedWidth(graphWidth: CGFloat) -> CGFloat {
        width(of: .refs) + graphWidth + trailingColumns.reduce(0) { $0 + width(of: $1) }
    }

    /// A divider drag inside a panel `panelWidth` wide: widening stops where Message would drop under its minimum;
    /// narrowing always applies.
    func resizing(_ column: Column, by delta: CGFloat, panelWidth: CGFloat, graphWidth: CGFloat) -> GraphColumnLayout {
        let room = max(0, panelWidth - fixedWidth(graphWidth: graphWidth) - Self.messageMinimum)
        return resizing(column, by: min(delta, room))
    }

    /// The `⋯` menu: shows or hides Author, Date, or SHA. Refs stays.
    func toggling(_ column: Column) -> GraphColumnLayout {
        guard column.isHideable else { return self }
        var copy = self
        if copy.hidden.contains(column) { copy.hidden.remove(column) } else { copy.hidden.insert(column) }
        return copy
    }

    func limitState(of column: Column) -> PanelLayout.LimitState {
        let width = width(of: column)
        let limits = column.limits
        if width <= limits.minimum + 0.5 { return .atMinimum }
        if width >= limits.maximum - 0.5 { return .atMaximum }
        return .between
    }

    /// Stored values from another version: unknown columns dropped, widths clamped to the current ranges, Refs
    /// visible.
    func sanitized() -> GraphColumnLayout {
        var copy = self
        copy.widths = widths.reduce(into: [:]) { result, entry in
            guard entry.value.isFinite else { return }
            result[entry.key] = Self.clamp(entry.value, entry.key.limits)
        }
        copy.hidden = hidden.filter(\.isHideable)
        return copy
    }

    /// Double-clicking a divider fits the column to what the loaded rows show (interaction.md §2.1): the widest
    /// content plus the cell's padding, within the column's range. Without content the column goes back to its ideal.
    static func fittedWidth(_ column: Column, contentWidths: some Sequence<CGFloat>) -> CGFloat {
        guard let widest = contentWidths.max() else { return column.limits.ideal }
        return clamp(widest.rounded(.up) + cellPadding(column), column.limits)
    }

    /// Horizontal padding around a cell's content: the text cells pad 8pt each side, the Refs cell 4pt.
    static func cellPadding(_ column: Column) -> CGFloat {
        column == .refs ? Tokens.Spacing.xs * 2 : Tokens.Spacing.sm * 2
    }

    private static func clamp(_ value: CGFloat, _ limits: PanelLayout.Limits) -> CGFloat {
        min(max(value, limits.minimum), limits.maximum)
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case widths
        case hidden
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Keys by name, so a column a later version adds or drops does not make the whole value unreadable.
        let rawWidths = (try? container.decodeIfPresent([String: CGFloat].self, forKey: .widths)) ?? [:]
        let rawHidden = (try? container.decodeIfPresent([String].self, forKey: .hidden)) ?? []
        self.init(
            widths: rawWidths.reduce(into: [:]) { result, entry in
                if let column = Column(rawValue: entry.key) { result[column] = entry.value }
            },
            hidden: Set(rawHidden.compactMap(Column.init(rawValue:))))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            Dictionary(uniqueKeysWithValues: widths.map { ($0.key.rawValue, $0.value) }), forKey: .widths)
        try container.encode(hidden.map(\.rawValue).sorted(), forKey: .hidden)
    }
}
