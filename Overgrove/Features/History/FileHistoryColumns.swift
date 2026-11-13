import CoreGraphics

/// Which S-09 columns fit a width (#579). Commit and Message always show; the fixed columns right of Message give way
/// one at a time, Author first, then This file, then Date, until Message keeps its minimum
/// (`GraphColumnLayout.messageMinimum`, art-direction.md §5.1). The row's VoiceOver label still reads every value.
struct FileHistoryColumns: Equatable, Sendable {
    enum Column: CaseIterable, Sendable {
        case author
        case date
        case stat

        var width: CGFloat {
            switch self {
            case .author: Tokens.Size.columnAuthorIdeal
            case .date: Tokens.Size.columnDateIdeal
            case .stat: FileHistoryColumns.statWidth
            }
        }
    }

    static let commitWidth: CGFloat = 120
    static let statWidth: CGFloat = 96
    /// The order the columns give way in.
    static let hidingOrder: [Column] = [.author, .stat, .date]

    let visible: Set<Column>

    init(width: CGFloat) {
        var visible = Set(Column.allCases)
        for column in Self.hidingOrder where Self.messageWidth(width, visible) < GraphColumnLayout.messageMinimum {
            visible.remove(column)
        }
        self.visible = visible
    }

    func shows(_ column: Column) -> Bool { visible.contains(column) }

    /// What Message gets at `width`.
    func messageWidth(in width: CGFloat) -> CGFloat { Self.messageWidth(width, visible) }

    private static func messageWidth(_ width: CGFloat, _ visible: Set<Column>) -> CGFloat {
        width - commitWidth - visible.reduce(0) { $0 + $1.width }
    }
}
