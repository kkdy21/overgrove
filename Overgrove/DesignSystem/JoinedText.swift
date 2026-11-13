import SwiftUI

/// Values joined into one line (`3 changed · 0 untracked · 0 conflicts`, `origin/main  ↑1 ↓0`) that fold between
/// items, never inside one, in a narrow panel (#612):
/// - an item's own spaces do not break (`3 changed`, `↑1 ↓0`, `working tree`);
/// - a separator only ever stands between two items on the same line, so no line starts or ends with `·`.
///
/// It picks the first grouping that fits, fewest lines first, keeping the items in order. When even one item per line
/// is too wide, that layout is used and each item folds or shortens on its own (`itemLineLimit`, middle truncation).
struct JoinedText: View {
    let items: [String]
    /// Drawn between items on a line: ` · ` by default; `nil` joins with two spaces (a name and its counts).
    var separator: String? = "·"
    /// How many lines one item may take when it is too wide for a line of its own.
    var itemLineLimit = 2

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(Self.groupings(count: items.count).enumerated()), id: \.offset) { _, lines in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, range in
                        Text(line(range)).fixedSize()
                    }
                }
            }
            // The fallback: one item per line, each allowed to fold or shorten.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text(Self.unbreakable(item)).lineLimit(itemLineLimit).truncationMode(.middle)
                }
            }
        }
    }

    private func line(_ range: Range<Int>) -> String {
        items[range].map(Self.unbreakable).joined(separator: separator.map { " \($0) " } ?? "  ")
    }

    /// The text as one line reads it: `items` joined, for VoiceOver, copying, and tests. Non-isolated: the models
    /// that build the plain value are not on the main actor.
    nonisolated static func joined(_ items: [String], separator: String? = "·") -> String {
        items.joined(separator: separator.map { " \($0) " } ?? "  ")
    }

    /// An item's spaces become no-break spaces, so the item stays on one line.
    nonisolated static func unbreakable(_ item: String) -> String {
        item.replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    /// Every way to cut `count` items into consecutive lines, fewest lines first (one line, then two, …), and within
    /// the same number of lines the ones that fill the first line most first. The all-separate grouping is left to
    /// the fallback.
    nonisolated static func groupings(count: Int) -> [[Range<Int>]] {
        guard count > 1 else { return count == 1 ? [[0..<1]] : [] }
        var result: [[Range<Int>]] = []
        // Each of the `count - 1` gaps between items either breaks the line or not.
        for mask in 0..<(1 << (count - 1)) {
            var lines: [Range<Int>] = []
            var start = 0
            for gap in 0..<(count - 1) where mask & (1 << gap) != 0 {
                lines.append(start..<(gap + 1))
                start = gap + 1
            }
            lines.append(start..<count)
            if lines.count < count { result.append(lines) }
        }
        return result.sorted {
            $0.count != $1.count ? $0.count < $1.count : $0[0].count > $1[0].count
        }
    }
}
