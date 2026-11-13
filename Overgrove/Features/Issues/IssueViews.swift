import AppKit
import SwiftUI

/// The sidebar's ISSUES section (screens.md S-06): `#12` and the title, a spinner in the header while gh runs, and
/// one notice row when the list is not available.
struct IssueListSection: View {
    let model: IssueListModel
    let selectedNumber: Int?
    let onSelect: (Int) -> Void
    /// Check Again in the degraded states (#83).
    var onCheckAgain: () -> Void = {}
    /// Open or closed, owned by the sidebar so the arrow keys and `⌘4` can open it (#592); `nil` keeps it here.
    var expansion: Binding<Bool>?
    /// The sidebar has keyboard focus (#592): the selected row is `surface.selection`, otherwise inactive.
    var isListFocused = false

    @State private var ownExpanded = true
    private var isExpanded: Binding<Bool> { expansion ?? $ownExpanded }

    var body: some View {
        Section {
            // Rows are direct children of the sidebar's lazy stack so `scrollTo` finds them (review of #598). Keyboard
            // focus, `↑`/`↓`, and `⌘4` belong to the whole sidebar (`SidebarPanel`, #592).
            if isExpanded.wrappedValue {
                if let account = model.account {
                    IssueAccountRow(account: account)
                }
                if let notice = model.notice {
                    SidebarNotice(symbol: notice.symbol, text: notice.text)
                        .help(notice.detail ?? notice.text)
                }
                if !model.setupCommands.isEmpty || model.canCheckAgain {
                    IssueSetupHint(
                        message: model.setupMessage, commands: model.setupCommands,
                        canCheckAgain: model.canCheckAgain,
                        isChecking: model.isLoading, onCheckAgain: onCheckAgain)
                }
                // Up to 200 rows (`--limit 200`).
                ForEach(model.rows, id: \.sidebarScrollID) { row in
                    IssueRowView(row: row, isSelected: row.id == selectedNumber, isListFocused: isListFocused)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(row.id) }
                        .accessibilityAction { onSelect(row.id) }
                        .contextMenu { IssueRowMenu(row: row) }
                }
            }
        } header: {
            SidebarSectionHeader(
                title: String(localized: "ISSUES", comment: "Sidebar section"), count: model.count,
                isExpanded: isExpanded, isLoading: model.isLoading)
        }
    }
}

/// Under the ISSUES header (ADR-0025 §4): the gh account the issues are read as, `login@host`. With more accounts on
/// the host, `+n more` and the command to switch, to copy into Terminal; Overgrove never switches accounts.
private struct IssueAccountRow: View {
    let account: GHAccount

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
            HStack(spacing: Tokens.Spacing.xs) {
                Image(systemName: "person.crop.circle").accessibilityHidden(true)
                Text(account.text).lineLimit(1).truncationMode(.middle)
                if let more = account.moreText {
                    Text(more).foregroundStyle(Tokens.Color.textTertiary)
                }
            }
            .font(Tokens.Font.caption)
            .foregroundStyle(Tokens.Color.textSecondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                String(localized: "gh account \(account.text)") + (account.moreText.map { ", \($0)" } ?? "")
            )
            .help("Issues and pull requests are read as \(account.text).")
            if let command = account.switchCommand {
                HStack(spacing: Tokens.Spacing.xs) {
                    // Wraps instead of truncating: the whole command must be readable before it is copied.
                    Text("$ " + command)
                        .font(Tokens.Font.monoSmall)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        // Copying to the clipboard is not a write (ADR-0011, ADR-0021 §3).
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc").hitTarget()
                    }
                    .buttonStyle(.borderless)
                    .help("Copy the command to switch accounts in Terminal")
                    .accessibilityLabel("Copy command \(command)")
                }
            }
        }
        .padding(.leading, SidebarInset.content + Tokens.Spacing.lg)
        .padding(.trailing, SidebarInset.content)
        .padding(.bottom, Tokens.Spacing.xs)
    }
}

/// Under a degraded ISSUES notice (#83): what to run in Terminal, a Copy button per command, and Check Again. gh's
/// texts are the shared `GHStatusGuidance` (S-07 says the same); a host no CLI is logged in to lists one login command
/// per CLI (ADR-0026 §7). Laid out narrow for the sidebar. Overgrove never runs the commands.
private struct IssueSetupHint: View {
    let message: String?
    let commands: [String]
    let canCheckAgain: Bool
    var isChecking = false
    let onCheckAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            if let message {
                Text(message)
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(commands, id: \.self) { command in
                HStack(spacing: Tokens.Spacing.xs) {
                    Text("$ " + command)
                        .font(Tokens.Font.monoSmall)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .padding(.horizontal, Tokens.Spacing.xs)
                        .padding(.vertical, Tokens.Spacing.xxs)
                        .background(
                            RoundedRectangle(cornerRadius: Tokens.Radius.sm).strokeBorder(Tokens.Color.borderStrong))
                    Button {
                        // Copying to the clipboard is not a repository write (ADR-0011).
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc").hitTarget()
                    }
                    .buttonStyle(.borderless)
                    .help("Copy")
                    .accessibilityLabel("Copy command \(command)")
                }
            }
            if canCheckAgain {
                Button(action: onCheckAgain) { Label("Check Again", systemImage: "arrow.clockwise") }
                    .controlSize(.small)
                    .disabled(isChecking)
            }
        }
        .padding(.leading, SidebarInset.content + Tokens.Spacing.lg)
        .padding(.trailing, SidebarInset.content)
        .padding(.bottom, Tokens.Spacing.xs)
    }
}

private struct IssueRowView: View {
    let row: IssueRow
    let isSelected: Bool
    /// The list has keyboard focus: the selection is `surface.selection`, otherwise `selection-inactive`.
    var isListFocused = false

    var body: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            Text(row.number).font(Tokens.Font.monoSmall).foregroundStyle(Tokens.Color.textSecondary)
            Text(row.title).font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textPrimary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            switch row.linkKind {
            case .worktree:
                Image(systemName: "tree").foregroundStyle(Tokens.Color.textSecondary).help("Linked worktree")
            case .branch:
                Image(systemName: "arrow.triangle.branch").foregroundStyle(Tokens.Color.textSecondary)
                    .help("Linked branch")
            case nil:
                EmptyView()
            }
        }
        .padding(.horizontal, Tokens.Spacing.sm)
        .frame(height: Tokens.Size.rowSidebar)
        // One selection style for every sidebar row, and hover feedback on the others (#572).
        .background {
            if isSelected { SidebarSelectionBackground(isFocused: isListFocused) }
        }
        .hoverHighlight(.inset, isEnabled: !isSelected)
        .padding(.horizontal, SidebarInset.row)
        .help(row.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// S-06, one issue (screens.md S-06). Read-only: no comment, edit, or close (ADR-0004); the body is not rendered.
struct IssueDetailView: View {
    let model: IssueDetailModel
    var onSelectWorktree: (GitPath) -> Void = { _ in }
    /// A linked branch's tip or a linked commit, selected in the graph.
    var onSelectCommit: (ObjectID) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
                    header
                    info
                    linked
                    Text(IssueDetailModel.bodyNotice)
                        .font(Tokens.Font.callout)
                        .foregroundStyle(Tokens.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Tokens.Spacing.md)
            }
            // Pinned on `surface.panel-header` like the panel's head (#578).
            PanelFooter {
                Button("Open in Browser") {
                    if let url = model.browserURL { NSWorkspace.shared.open(url) }
                }
                .disabled(model.browserURL == nil)
                .help(
                    model.browserURL == nil
                        ? String(localized: "This link is not an issue page on this repository's host.") : model.urlText
                )
                Button("Copy URL") {
                    // Copying to the clipboard is not a repository write (ADR-0011).
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.urlText, forType: .string)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            (Text(model.number).foregroundStyle(Tokens.Color.textSecondary) + Text("  ")
                + Text(model.title).foregroundStyle(Tokens.Color.textPrimary))
                .font(Tokens.Font.headline)
                // Combining marks are not escaped; a title cannot grow without bound.
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .help(model.title)
            HStack(spacing: Tokens.Spacing.xs) {
                // A neutral pill: the state is text and symbol, not a status color (screens.md S-06).
                Label(model.stateText, systemImage: model.stateSymbol)
                    .font(Tokens.Font.pill)
                    .foregroundStyle(Tokens.Color.textSecondary)
                    .padding(.horizontal, Tokens.Spacing.xs + Tokens.Spacing.xxs)
                    .padding(.vertical, Tokens.Spacing.xxs)
                    .background(Capsule().fill(Tokens.Color.surfaceRaised))
                    .controlOutline(Capsule())
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(
                        ([model.repository].compactMap { $0 } + [
                            "updated " + StatusBarItem.relative(model.updatedAt, now: context.date)
                        ]).joined(separator: " · ")
                    )
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Color.textTertiary)
                    .lineLimit(1)
                }
            }
        }
    }

    private var info: some View {
        DetailCard {
            Grid(
                alignment: .leadingFirstTextBaseline, horizontalSpacing: Tokens.Spacing.md,
                verticalSpacing: Tokens.Spacing.xs
            ) {
                GridRow {
                    label("Labels")
                    if model.labels.isEmpty {
                        none
                    } else {
                        FlowLayout(spacing: Tokens.Spacing.xs) {
                            ForEach(Array(model.labels.enumerated()), id: \.offset) { _, name in
                                Text(name)
                                    .font(Tokens.Font.pill)
                                    .foregroundStyle(Tokens.Color.textSecondary)
                                    .lineLimit(1)
                                    .padding(.horizontal, Tokens.Spacing.xs + Tokens.Spacing.xxs)
                                    .padding(.vertical, Tokens.Spacing.xxs)
                                    .background(Capsule().fill(Tokens.Color.surfaceControl))
                                    .controlOutline(Capsule(), normal: nil)
                            }
                        }
                    }
                }
                GridRow {
                    label("Assignees")
                    if model.assignees.isEmpty {
                        none
                    } else {
                        Text(model.assignees.joined(separator: ", "))
                            .font(Tokens.Font.callout)
                            .foregroundStyle(Tokens.Color.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// LINKED (screens.md S-06): worktrees, branches, then the latest five commits; each selects its item.
    @ViewBuilder
    private var linked: some View {
        DetailCard {
            Text("LINKED")
                .font(Tokens.Font.sectionHeader)
                .tracking(Tokens.Font.sectionHeaderTracking)
                .foregroundStyle(Tokens.Color.textTertiary)
            if model.linkedWorktrees.isEmpty && model.linkedBranches.isEmpty && model.linkedCommits.isEmpty
                && model.hiddenLinkCount == 0
            {
                Text("No branch, worktree, or loaded commit mentions this issue.")
                    .font(Tokens.Font.callout)
                    .foregroundStyle(Tokens.Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.linkedWorktrees, id: \.path) { link in
                linkRow(symbol: "tree", text: link.title, note: "worktree") { onSelectWorktree(link.path) }
            }
            ForEach(model.linkedBranches, id: \.fullName) { link in
                linkRow(symbol: link.isRemote ? "network" : "arrow.triangle.branch", text: link.title, note: nil) {
                    if let target = link.target { onSelectCommit(target) }
                }
            }
            if model.hiddenLinkCount > 0 {
                Text("and \(model.hiddenLinkCount) more branches or worktrees")
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Color.textTertiary)
            }
            ForEach(model.linkedCommits) { link in
                linkRow(symbol: "smallcircle.filled.circle", text: link.subject, note: nil, sha: link.shortSHA) {
                    onSelectCommit(link.id)
                }
            }
        }
    }

    private func linkRow(
        symbol: String, text: String, note: String?, sha: String? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Tokens.Spacing.xs) {
                Image(systemName: symbol).foregroundStyle(Tokens.Color.textSecondary).accessibilityHidden(true)
                if let sha {
                    Text(sha).font(Tokens.Font.monoSmall).foregroundStyle(Tokens.Color.textSecondary)
                }
                // A commit subject or title is cut at its end, like every other row (#579).
                Text(text).font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textPrimary)
                    .lineLimit(1).truncationMode(.tail)
                if let note {
                    Text("(\(note))").font(Tokens.Font.caption).foregroundStyle(Tokens.Color.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(.rounded(radius: Tokens.Radius.sm))
        .help(text)
        .accessibilityLabel([sha, text, note].compactMap { $0 }.joined(separator: " "))
    }

    private func label(_ text: LocalizedStringKey) -> some View {
        Text(text).font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textTertiary)
    }

    private var none: some View {
        Text("None").font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textTertiary)
    }
}

/// Left-aligned rows that wrap, for label pills.
private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, width: bounds.width)
        for (index, origin) in rows.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: ProposedViewSize(rows.sizes[index]))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (
        origins: [CGPoint], sizes: [CGSize], width: CGFloat, height: CGFloat
    ) {
        var origins: [CGPoint] = []
        var sizes: [CGSize] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            // A pill wider than the row is cut to the row (its text truncates).
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            sizes.append(size)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, sizes, widest, y + rowHeight)
    }
}

/// An issue row's menu (interaction.md §5): Open in Browser opens only an issue page on the
/// repository's host over https.
private struct IssueRowMenu: View {
    let row: IssueRow

    @Environment(\.rowMenu) private var actions

    var body: some View {
        Button("Open in Browser") { if let url = row.browserURL { actions.openInBrowser(url) } }
            .disabled(row.browserURL == nil)
        Button("Show Linked Branch") { if let tip = actions.linkedBranchTip(row.id) { actions.showCommit(tip) } }
            .disabled(actions.linkedBranchTip(row.id) == nil)
        Divider()
        Button("Copy URL") { actions.copy(row.urlText) }
        Button("Copy Number") { actions.copy(row.number) }
    }
}

extension IssueRow {
    /// The id `ForEach` and `scrollTo` share (#592).
    var sidebarScrollID: String { SidebarItem.issue(id).scrollID }
}
