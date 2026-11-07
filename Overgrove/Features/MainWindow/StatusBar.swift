import SwiftUI

/// One field of the main window's status bar (art-direction.md §3.5, interaction.md §4.2).
struct StatusBarItem: Equatable, Identifiable {
    enum Kind: Equatable, Sendable {
        case readOnly
        case fetch
        /// `Refreshing…` with a small spinner while local data reloads (interaction.md §4).
        case refreshing
        case aheadBehind
        /// The focused worktree's last status was slow (#168); the tooltip explains why.
        case slowStatus
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
    /// A tooltip that explains the field (the slow-status hint, #168).
    var help: String?

    var id: Kind { kind }
    /// The gh status sits at the trailing end; everything else is on the leading side.
    var isTrailing: Bool { kind == .gh }

    /// The fields in display order. Repository fields appear only once their data exists; gh only once checked.
    static func items(
        snapshot: RepositorySnapshot?,
        fetchStatus: FetchStatus,
        ghStatus: GHAuthStatus?,
        now: Date,
        hasFetchDetails: Bool = false,
        isRefreshing: Bool = false,
        fetchRemoteLimit: FetchRemoteLimit? = nil
    ) -> [StatusBarItem] {
        var fetch = fetchItem(fetchStatus, now: now, hasDetails: hasFetchDetails)
        // `Fetched just now · 16 of 40 remotes` (#259); not while a new fetch runs.
        if let fetchRemoteLimit, !fetchStatus.isFetching {
            fetch = StatusBarItem(
                kind: .fetch, text: fetch.text + " · " + fetchRemoteLimit.short, symbol: fetch.symbol, tone: fetch.tone)
        }
        var items = [
            StatusBarItem(kind: .readOnly, text: "Read-only", symbol: "checkmark.shield", tone: .ok),
            fetch,
        ]
        if isRefreshing {
            items.append(StatusBarItem(kind: .refreshing, text: "Refreshing…", symbol: nil, tone: .neutral))
        }
        if let snapshot {
            if let worktree = snapshot.focusedWorktree, worktree.hasUpstream {
                items.append(
                    StatusBarItem(
                        kind: .aheadBehind, text: "↑\(worktree.ahead) ↓\(worktree.behind)", symbol: nil, tone: .neutral)
                )
            }
            if let slow = snapshot.focusedWorktree?.slowStatus {
                items.append(
                    StatusBarItem(
                        kind: .slowStatus, text: slow.short, symbol: "tortoise", tone: .warning, help: slow.message))
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

    private static func fetchItem(_ status: FetchStatus, now: Date, hasDetails: Bool) -> StatusBarItem {
        switch status {
        case .never:
            return StatusBarItem(kind: .fetch, text: "Never fetched", symbol: "arrow.clockwise", tone: .neutral)
        case .idle(let last):
            return StatusBarItem(
                kind: .fetch, text: "Fetched \(relative(last, now: now))", symbol: "arrow.clockwise", tone: .neutral)
        case .estimated(let last):
            return StatusBarItem(
                kind: .fetch, text: "Fetched \(relative(last, now: now)) (estimated)", symbol: "arrow.clockwise",
                tone: .neutral)
        case .fetching(let remotes, let since, _):
            let what: String
            switch remotes.count {
            case 0: what = ""
            case 1: what = " " + remotes[0]
            default: what = " \(remotes.count) remotes"
            }
            let seconds = max(0, Int(now.timeIntervalSince(since)))
            return StatusBarItem(
                kind: .fetch, text: "Fetching\(what)… \(seconds) s", symbol: "arrow.down.circle", tone: .neutral)
        case .failed(let last):
            var text = last.map { "Last fetched \(relative($0, now: now)) · last attempt failed" } ?? "Fetch failed"
            if hasDetails { text += " — Details" }
            return StatusBarItem(kind: .fetch, text: text, symbol: "exclamationmark.triangle", tone: .warning)
        case .cancelled:
            return StatusBarItem(kind: .fetch, text: "Fetch cancelled", symbol: "arrow.clockwise", tone: .neutral)
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
    /// Opens the fetch failure details (`Fetch failed — Details`); `nil` makes the fetch field plain text.
    var onFetchDetails: (() -> Void)?
    /// Opens the setup assistant's GitHub step (S-07, #83); `nil` makes the gh field plain text.
    var onGitHubSetup: (() -> Void)?

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
            if item.kind == .fetch, let onFetchDetails {
                Button(action: onFetchDetails) { field(item) }
                    .buttonStyle(.plain)
                    .help("Show why the fetch failed")
                    .accessibilityHint("Shows why the fetch failed and what to do")
            } else if item.kind == .gh, let onGitHubSetup {
                Button(action: onGitHubSetup) { field(item) }
                    .buttonStyle(.plain)
                    .help("GitHub CLI setup")
                    .accessibilityHint("Opens the setup assistant")
            } else if let help = item.help {
                field(item).help(help).accessibilityHint(help)
            } else {
                field(item)
            }
        }
    }

    /// Leading fields put the icon first; the trailing gh status puts it last (`gh: @login ✓`, §3.5).
    private func field(_ item: StatusBarItem) -> some View {
        HStack(spacing: Tokens.Spacing.xs) {
            if item.kind == .refreshing {
                ProgressView().controlSize(.mini).accessibilityHidden(true)
            } else if !item.isTrailing {
                icon(item)
            }
            Text(item.text)
            if item.isTrailing { icon(item) }
        }
        .foregroundStyle(item.tone == .warning ? color(for: .warning) : Tokens.Color.textSecondary)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func icon(_ item: StatusBarItem) -> some View {
        if let symbol = item.symbol {
            Image(systemName: symbol).foregroundStyle(color(for: item.tone)).accessibilityHidden(true)
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
