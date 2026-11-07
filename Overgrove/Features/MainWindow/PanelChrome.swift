import SwiftUI

/// The 40pt strip at the top of every panel: `surface.panel-header` with a `border.separator` line below
/// (art-direction.md §3, `size.panel-header`).
struct PanelHeader<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            content
        }
        .padding(.horizontal, Tokens.Spacing.md)
        .frame(height: Tokens.Size.panelHeader)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Color.surfacePanelHeader)
        .overlay(alignment: .bottom) {
            Tokens.Color.borderSeparator.frame(height: 1)
        }
    }
}

/// A panel with its header and a body that fills the rest.
struct PanelSection<Header: View, Content: View>: View {
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader { header }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// What a panel shows before its feature or its data is there.
struct PanelEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: Tokens.Spacing.sm) {
            Image(systemName: symbol)
                .font(Tokens.Font.title)
                .foregroundStyle(Tokens.Color.textTertiary)
                .accessibilityHidden(true)
            Text(title)
                .font(Tokens.Font.headline)
                .foregroundStyle(Tokens.Color.textSecondary)
            Text(message)
                .font(Tokens.Font.callout)
                .foregroundStyle(Tokens.Color.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(Tokens.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A non-interactive stand-in for a field that a later feature makes live (the sidebar filter).
struct PlaceholderField: View {
    let symbol: String
    let prompt: String
    let shortcut: String

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(prompt)
            Spacer(minLength: Tokens.Spacing.sm)
            Text(shortcut).font(Tokens.Font.monoSmall)
        }
        .font(Tokens.Font.callout)
        .foregroundStyle(Tokens.Color.textTertiary)
        .padding(.horizontal, Tokens.Spacing.sm)
        .frame(height: Tokens.Size.rowSidebar)
        .background(Tokens.Color.surfaceControl, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(prompt)
        .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - The three panels of S-01

/// Sidebar: filter header, then WORKTREES / LOCAL / REMOTE / STASHES / ISSUES.
struct SidebarPanel: View {
    let hasRepository: Bool
    var worktreeStatus: WorktreeListStatus = .idle
    var worktreeModel: WorktreeListModel?
    var selectedWorktree: GitPath?
    var onSelectWorktree: (GitPath) -> Void = { _ in }

    var body: some View {
        PanelSection {
            // TODO(#74): filter the sidebar.
            PlaceholderField(symbol: "magnifyingglass", prompt: "Filter", shortcut: "⌥⌘F")
        } content: {
            if hasRepository {
                // TODO(#72): LOCAL and REMOTE; TODO(#71): STASHES; TODO(#81): ISSUES.
                ScrollView {
                    WorktreeListSection(
                        status: worktreeStatus, model: worktreeModel, selectedPath: selectedWorktree,
                        onSelect: onSelectWorktree)
                }
            } else {
                PanelEmptyState(
                    symbol: "folder", title: "No repository open",
                    message: "Add a repository to see its worktrees.")
            }
        }
    }
}

/// Center: author filter header, column headers, and the commit graph. TODO(#68): commit graph.
struct GraphPanel: View {
    let hasRepository: Bool

    var body: some View {
        PanelSection {
            Image(systemName: "person.2").foregroundStyle(Tokens.Color.textSecondary).accessibilityHidden(true)
            Text("Commits").font(Tokens.Font.headline).foregroundStyle(Tokens.Color.textPrimary)
        } content: {
            PanelEmptyState(
                symbol: "point.3.connected.trianglepath.dotted", title: "Commit graph",
                message: hasRepository
                    ? "The history of every worktree appears here." : "Open a repository to see its history.")
        }
    }
}

/// Detail: the focused worktree's changes or the selected item. TODO(#66): WIP detail; TODO(#67): worktree detail.
struct DetailPanel: View {
    let focusedWorktree: FocusedWorktree?

    var body: some View {
        PanelSection {
            Image(systemName: "tree.fill").foregroundStyle(Tokens.Color.textSecondary).accessibilityHidden(true)
            Text(focusedWorktree?.title ?? "No selection")
                .font(Tokens.Font.headline)
                .foregroundStyle(Tokens.Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        } content: {
            PanelEmptyState(
                symbol: "doc.text.magnifyingglass", title: "Details",
                message: "Changes in the focused worktree or the selected commit appear here.")
        }
    }
}
