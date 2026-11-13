import SwiftUI

/// One file in a detail file list (#577): S-02, S-03, S-04, S-11, and S-12 all draw this row, so height, kind badge,
/// path, and line counts match everywhere (design-tokens.md §3.6, art-direction.md §4.4, §7).
struct FileRowView: View {
    /// The 16pt kind badge in front of the path.
    enum Badge: Equatable {
        /// Filled with a status colour (`status.*` with `on-status.*`), as in S-02's groups.
        case status(letter: String, group: WorkingChangeGroup)
        /// A committed change has no staged/unstaged state: same shape, neutral fill.
        case neutral(letter: String)
        /// The kind is not known (a stash's tracked files come from numstat only): empty space keeps the column.
        case unknown
    }

    let badge: Badge
    /// Leading directories with a trailing `/`, or empty. Escaped.
    let directory: String
    /// The file name, or `{old → new}`. Escaped.
    let fileName: String
    var lineCount: WipLineCount?
    /// A small outlined pill after the path (`submodule`, `WIP`).
    var pill: LocalizedStringKey?
    let isSelectable: Bool
    let isSelected: Bool
    /// The selection is accent-tinted only while the list has focus; lists without their own focus pass `true`.
    var isListFocused = true

    var body: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            FileKindBadge(badge: badge)
            path
            if let pill {
                Text(pill)
                    .font(Tokens.Font.pill)
                    .foregroundStyle(Tokens.Color.textSecondary)
                    .padding(.horizontal, Tokens.Spacing.xs)
                    .controlOutline(Capsule())
                    .fixedSize()
            }
            Spacer(minLength: 0)
            switch lineCount {
            case .lines(let added, let deleted):
                LineCountText(added: added, deleted: deleted).font(Tokens.Font.monoSmall).layoutPriority(2)
            case .binary:
                Text("binary").font(Tokens.Font.caption).foregroundStyle(Tokens.Color.textTertiary).fixedSize()
                    .layoutPriority(2)
            case nil:
                EmptyView()
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .frame(height: Tokens.Size.rowFile)
        .background {
            if isSelected {
                let shape = RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                // `surface.selection-inactive` equals `surface.raised` in light mode, so on a card the inactive
                // selection also gets an outline to stay visible.
                shape
                    .fill(isListFocused ? Tokens.Color.surfaceSelection : Tokens.Color.surfaceSelectionInactive)
                    .overlay(shape.strokeBorder(isListFocused ? Color.clear : Tokens.Color.borderStrong))
                    .padding(.horizontal, Self.selectionInset)
            }
        }
        .hoverHighlight(
            .rounded(radius: Tokens.Radius.md), isEnabled: !isSelected && isSelectable,
            horizontalInset: Self.selectionInset)
    }

    /// The directory gives way first and loses its leading part; the file name stays whole as long as it fits
    /// (screens.md S-02 "길면 디렉터리 앞부분을 `…/`로 줄인다").
    private var path: some View {
        HStack(spacing: 0) {
            if !directory.isEmpty {
                Text(directory)
                    .foregroundStyle(Tokens.Color.textTertiary)
                    .truncationMode(.head)
                    .layoutPriority(0)
            }
            Text(fileName)
                .foregroundStyle(isSelectable ? Tokens.Color.textPrimary : Tokens.Color.textTertiary)
                .fontWeight(.medium)
                .truncationMode(.middle)
                .layoutPriority(1)
        }
        .font(Tokens.Font.callout)
        .lineLimit(1)
    }

    /// screens.md S-02: a 16pt square badge. No size token for it.
    static let badgeSize: CGFloat = 16
    /// Where the badge starts; commit rows above a file list use it too, so both start on one line (#577).
    static let horizontalPadding = Tokens.Spacing.sm + Tokens.Spacing.xxs
    /// The selection and hover fills sit this far inside the row.
    static let selectionInset = Tokens.Spacing.xs
}

/// The 16pt kind badge (art-direction.md §4.4), also used as the S-04 legend's icon.
struct FileKindBadge: View {
    let badge: FileRowView.Badge

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.sm)
        let size = FileRowView.badgeSize
        Group {
            switch badge {
            case .status(let letter, let group):
                Text(letter).foregroundStyle(group.onTint)
                    .background(shape.fill(group.tint).frame(width: size, height: size))
            case .neutral(let letter):
                Text(letter).foregroundStyle(Tokens.Color.textSecondary)
                    .background(shape.fill(Tokens.Color.surfaceControl).frame(width: size, height: size))
            case .unknown:
                // Only the space: a filled empty square reads as a checkbox.
                Color.clear
            }
        }
        .font(Tokens.Font.monoSmall)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension FileStat {
    /// Added and deleted lines for a file row (`binary` when numstat has no counts).
    var lineCount: WipLineCount {
        isBinary ? .binary : .lines(added: added ?? 0, deleted: deleted ?? 0)
    }
}
