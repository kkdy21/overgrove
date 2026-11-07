import SwiftUI

/// One field of the main window's status bar (art-direction.md §3.5, interaction.md §4.2).
struct StatusBarItem: Equatable, Identifiable {
    enum Kind: Equatable, Sendable {
        case readOnly
        case fetch
        case aheadBehind
        case worktrees
        case prunable
        case gh
    }

    enum Tone: Equatable, Sendable {
        case ok
        case neutral
        case warning
    }

    let kind: Kind
    let text: String
    let symbol: String?
    let tone: Tone

    var id: Kind { kind }
    /// The gh status sits at the trailing end; everything else is on the leading side.
    var isTrailing: Bool { kind == .gh }

    /// The fields in display order. Repository fields appear only once their data exists; gh only once checked.
    static func items(
        snapshot: RepositorySnapshot?,
        fetchStatus: FetchStatus,
        ghStatus: GHAuthStatus?,
        now: Date
    ) -> [StatusBarItem] {
        var items = [
            StatusBarItem(kind: .readOnly, text: "Read-only", symbol: "checkmark.shield", tone: .ok),
            fetchItem(fetchStatus, now: now),
        ]
        if let snapshot {
            if let worktree = snapshot.focusedWorktree, worktree.hasUpstream {
                items.append(
                    StatusBarItem(
                        kind: .aheadBehind, text: "↑\(worktree.ahead) ↓\(worktree.behind)", symbol: nil, tone: .neutral))
            }
            let count = snapshot.worktreeCount
            items.append(
                StatusBarItem(
                    kind: .worktrees, text: "\(count) \(count == 1 ? "worktree" : "worktrees")", symbol: nil,
                    tone: .neutral))
            if snapshot.prunableCount > 0 {
                items.append(
                    StatusBarItem(
                        kind: .prunable, text: "\(snapshot.prunableCount) prunable", symbol: "questionmark.folder",
                        tone: .warning))
            }
        }
        if let ghStatus {
            items.append(ghItem(ghStatus))
        }
        return items
    }

    private static func fetchItem(_ status: FetchStatus, now: Date) -> StatusBarItem {
        switch status {
        case .never:
            return StatusBarItem(kind: .fetch, text: "Never fetched", symbol: "arrow.clockwise", tone: .neutral)
        case .idle(let last):
            return StatusBarItem(
                kind: .fetch, text: "Fetched \(relative(last, now: now))", symbol: "arrow.clockwise", tone: .neutral)
        case .fetching(let remotes, let since, _):
            let what = remotes.count == 1 ? remotes[0] : "\(remotes.count) remotes"
            let seconds = max(0, Int(now.timeIntervalSince(since)))
            return StatusBarItem(
                kind: .fetch, text: "Fetching \(what)… \(seconds) s", symbol: "arrow.down.circle", tone: .neutral)
        case .failed(let last):
            let text = last.map { "Last fetched \(relative($0, now: now)) · last attempt failed" } ?? "Fetch failed"
            return StatusBarItem(kind: .fetch, text: text, symbol: "exclamationmark.triangle", tone: .warning)
        }
    }

    private static func ghItem(_ status: GHAuthStatus) -> StatusBarItem {
        switch status {
        case .loggedIn(let login):
            StatusBarItem(kind: .gh, text: "gh: @\(login)", symbol: "person.crop.circle.badge.checkmark", tone: .ok)
        case .notLoggedIn:
            StatusBarItem(
                kind: .gh, text: "gh: not logged in", symbol: "person.crop.circle.badge.xmark", tone: .neutral)
        case .notInstalled:
            StatusBarItem(
                kind: .gh, text: "gh: not installed", symbol: "person.crop.circle.badge.questionmark", tone: .neutral)
        }
    }

    /// `just now`, `2 min ago`, `3 h ago`, `2 d ago` (interaction.md §4.2 wording).
    static func relative(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "just now"
        case ..<3_600: return "\(seconds / 60) min ago"
        case ..<86_400: return "\(seconds / 3_600) h ago"
        default: return "\(seconds / 86_400) d ago"
        }
    }
}

/// The bar at the bottom of the main window: `surface.window`, `size.status-bar` high.
struct StatusBar: View {
    let items: [StatusBarItem]

    var body: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            fields(items.filter { !$0.isTrailing })
            Spacer(minLength: Tokens.Spacing.lg)
            fields(items.filter(\.isTrailing))
        }
        .font(Tokens.Font.caption)
        .foregroundStyle(Tokens.Color.textSecondary)
        .padding(.horizontal, Tokens.Spacing.lg)
        .frame(height: Tokens.Size.statusBar)
        .frame(maxWidth: .infinity)
        .background(Tokens.Color.surfaceWindow)
    }

    @ViewBuilder
    private func fields(_ items: [StatusBarItem]) -> some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            if index > 0 {
                // art-direction.md §3.5: a 3pt `text.quaternary` dot between fields.
                Circle()
                    .fill(Tokens.Color.textQuaternary)
                    .frame(width: Self.separatorDiameter, height: Self.separatorDiameter)
                    .accessibilityHidden(true)
            }
            Label {
                Text(item.text)
            } icon: {
                if let symbol = item.symbol {
                    Image(systemName: symbol).foregroundStyle(color(for: item.tone))
                }
            }
            .labelStyle(.titleAndIcon)
            .foregroundStyle(item.tone == .warning ? color(for: .warning) : Tokens.Color.textSecondary)
        }
    }

    /// No size token for the separator dot; the value comes from art-direction.md §3.5.
    static let separatorDiameter: CGFloat = 3

    private func color(for tone: StatusBarItem.Tone) -> Color {
        switch tone {
        case .ok: Tokens.Color.statusOk
        case .neutral: Tokens.Color.textSecondary
        case .warning: Tokens.Color.statusPrunable
        }
    }
}
