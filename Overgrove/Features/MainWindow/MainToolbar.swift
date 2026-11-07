import SwiftUI

/// The main window toolbar (screens.md S-01, art-direction.md §3.4).
///
/// Leading: sidebar toggle, repository switcher, focused-worktree chip. Center: Fetch, Refresh │ Compare │ Terminal,
/// Finder, icon above label. The search field is added by `MainWindowView` with `.searchable`.
///
/// ADR-0011: there is no Pull, Push, Commit, Branch, Stash, or Checkout, not even disabled.
struct MainToolbar: ToolbarContent {
    let repository: RepositoryContext?
    let repositoryMenu: RepositoryMenuModel
    let isAddingRepository: Bool
    let repositoryActions: RepositoryActions
    let focusedWorktree: FocusedWorktree?
    let isSidebarCollapsed: Bool
    let toggleSidebar: () -> Void
    /// ⌘R; `nil` (disabled) without a repository.
    var refresh: (() -> Void)?
    /// Compare with base (`⌘⇧B`, #158); `nil` disables the button.
    var onCompare: (() -> Void)?
    /// Fetch (`⌘⇧R`), or Stop while fetching (`⌘.`, same place; interaction.md §4.2). `nil` disables the button.
    var onFetch: (() -> Void)?
    var isFetching = false
    /// Jump to HEAD (`⌘J`) from the worktree chip; `nil` disables it.
    var onJumpToHead: (() -> Void)?
    /// Open in Terminal / Reveal in Finder for the focused worktree (#73's row actions); `nil` disables them.
    var onTerminal: (() -> Void)?
    var onFinder: (() -> Void)?

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: toggleSidebar) {
                Label(isSidebarCollapsed ? "Show Sidebar" : "Hide Sidebar", systemImage: "sidebar.left")
            }
            .help(isSidebarCollapsed ? "Show Sidebar (⌃⌘S)" : "Hide Sidebar (⌃⌘S)")

            RepositorySwitcher(
                repository: repository, model: repositoryMenu, isAdding: isAddingRepository,
                actions: repositoryActions)
            // Outside the menu: macOS reduces a menu label to its first text, which would drop the owner.
            if let owner = repository?.owner {
                Text(owner).foregroundStyle(Tokens.Color.textSecondary)
            }

            Image(systemName: "chevron.right")
                .foregroundStyle(Tokens.Color.textTertiary)
                .accessibilityHidden(true)

            WorktreeChip(worktree: focusedWorktree, onJumpToHead: onJumpToHead)
        }

        ToolbarItemGroup(placement: .principal) {
            ForEach(ToolbarAction.Group.allCases, id: \.self) { group in
                if group != ToolbarAction.Group.allCases.first {
                    ToolbarGroupSeparator()
                }
                ForEach(ToolbarAction.allCases.filter { $0.group == group }, id: \.self) { action in
                    if action == .compare {
                        ToolbarActionButton(
                            title: action.title, symbol: action.symbol, help: action.help, action: onCompare
                        )
                        .keyboardShortcut("b", modifiers: [.command, .shift])
                    } else if action == .fetch {
                        ToolbarActionButton(
                            title: isFetching ? "Stop" : action.title,
                            symbol: isFetching ? "stop.fill" : action.symbol,
                            help: isFetching ? "Stop fetching (⌘.)" : action.help, action: onFetch)
                    } else {
                        ToolbarActionButton(
                            title: action.title, symbol: action.symbol, help: action.help,
                            action: self.action(for: action))
                    }
                }
            }
        }
    }
}

extension MainToolbar {
    fileprivate func action(for action: ToolbarAction) -> (() -> Void)? {
        switch action {
        case .refresh: refresh
        case .terminal: onTerminal
        case .finder: onFinder
        case .fetch, .compare: nil
        }
    }
}

/// Every action in the toolbar's center group, in order (art-direction.md §3.4). The toolbar is built from this list,
/// so a test can check that no write action exists (ADR-0011).
enum ToolbarAction: CaseIterable, Hashable {
    case fetch
    case refresh
    case compare
    case terminal
    case finder

    enum Group: CaseIterable, Hashable {
        case sync
        case compare
        case open
    }

    var group: Group {
        switch self {
        case .fetch, .refresh: .sync
        case .compare: .compare
        case .terminal, .finder: .open
        }
    }

    var title: String {
        switch self {
        case .fetch: "Fetch"
        case .refresh: "Refresh"
        case .compare: "Compare"
        case .terminal: "Terminal"
        case .finder: "Finder"
        }
    }

    var symbol: String {
        switch self {
        case .fetch: "arrow.down.circle"
        case .refresh: "arrow.clockwise"
        case .compare: "plus.forwardslash.minus"
        case .terminal: "terminal"
        case .finder: "folder"
        }
    }

    var help: String {
        switch self {
        case .fetch: "Fetch all remotes (⌘⇧R)"
        case .refresh: "Refresh local data (⌘R)"
        case .compare: "Compare with base branch (⌘⇧B)"
        case .terminal: "Open the focused worktree in Terminal"
        case .finder: "Reveal the focused worktree in Finder"
        }
    }
}

/// An action shown as an icon above its label (NSToolbar icon-and-label look, art-direction.md §3.4).
/// Disabled until its feature lands; `action` is optional for that reason.
struct ToolbarActionButton: View {
    let title: String
    let symbol: String
    let help: String
    var action: (() -> Void)?

    var body: some View {
        Button {
            action?()
        } label: {
            VStack(spacing: Tokens.Spacing.xxs) {
                Image(systemName: symbol).imageScale(.large)
                Text(title).font(Tokens.Font.caption)
            }
            .frame(minWidth: Self.minimumWidth)
        }
        .buttonStyle(.borderless)
        .disabled(action == nil)
        .help(help)
        .accessibilityLabel(title)
    }

    /// Keeps short labels (Fetch, Finder) from making uneven buttons.
    static let minimumWidth: CGFloat = 48
}

/// `[◆ feat/42-rate-limit ↑2 ⌘J]`: the focused worktree. Pressing it scrolls the graph to its HEAD (`⌘J`).
/// TODO(#65): lane-color tint from the worktree's branch.
struct WorktreeChip: View {
    let worktree: FocusedWorktree?
    var onJumpToHead: (() -> Void)?

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if let worktree {
            Button {
                onJumpToHead?()
            } label: {
                HStack(spacing: Tokens.Spacing.xs) {
                    Image(systemName: "tree.fill")
                    Text(worktree.title).lineLimit(1).truncationMode(.middle)
                    if let ahead = worktree.aheadBadge {
                        Text(ahead).foregroundStyle(Tokens.Color.textSecondary)
                    }
                    Text("⌘J").font(Tokens.Font.monoSmall).foregroundStyle(Tokens.Color.textTertiary)
                }
                .padding(.horizontal, Tokens.Spacing.sm)
                .padding(.vertical, Tokens.Spacing.xxs)
                // Neutral until #65 supplies the branch's lane color (14% fill, 45% border, art-direction §3.4).
                .background(Tokens.Color.surfaceControl, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(
                        contrast == .increased ? Tokens.Color.borderStrong : Tokens.Color.borderSeparator,
                        lineWidth: Tokens.controlOutlineWidth(contrast)))
            }
            .buttonStyle(.borderless)
            .disabled(onJumpToHead == nil)
            .help("Jump to HEAD (⌘J)")
            .accessibilityLabel(worktree.accessibilityLabel)
            .accessibilityHint("Jump to HEAD")
        }
    }
}

/// The `│` between toolbar action groups (art-direction §3.4). `Divider` draws a horizontal dash in a toolbar.
struct ToolbarGroupSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Tokens.Color.borderSeparator)
            .frame(width: 1, height: Self.height)
            .accessibilityHidden(true)
    }

    /// About the height of an icon-over-label button; no token.
    static let height: CGFloat = 28
}
