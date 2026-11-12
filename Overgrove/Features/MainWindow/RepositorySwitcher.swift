import AppKit
import SwiftUI

/// What the repository menu lists (screens.md S-01): the registered repositories with the open one checked, then
/// `Add Repository…`, `Remove “<name>” from Overgrove` for the open one, and `Manage Repositories…`.
struct RepositoryMenuModel: Equatable {
    struct Item: Equatable, Identifiable {
        let id: RegisteredRepository.ID
        let name: String
        /// Shown as the item's help text, so two repositories with the same folder name can be told apart.
        let path: String
        let isOpen: Bool
    }

    let items: [Item]
    /// `nil` without an open repository.
    let removeTitle: String?

    init(repositories: [RegisteredRepository], openID: RegisteredRepository.ID?) {
        items = repositories.map {
            Item(id: $0.id, name: $0.name, path: $0.displayRootPath, isOpen: $0.id == openID)
        }
        removeTitle = repositories.first { $0.id == openID }.map {
            String(localized: "Remove “\($0.name)” from Overgrove")
        }
    }
}

/// What the repository menu, the File menu, and the manage sheet can do in one window.
@MainActor
struct RepositoryActions {
    let open: (RegisteredRepository.ID) -> Void
    let add: () -> Void
    let remove: (RegisteredRepository.ID) -> Void
    let manage: () -> Void
}

/// `[▭ api acme ⌃]`: switch, add, and remove registered repositories.
struct RepositorySwitcher: View {
    let repository: RepositoryContext?
    let model: RepositoryMenuModel
    let isAdding: Bool
    let actions: RepositoryActions

    var body: some View {
        Menu {
            if !model.items.isEmpty {
                ForEach(model.items) { item in
                    // A toggle draws the menu checkmark for the open repository.
                    Toggle(
                        item.name,
                        isOn: Binding(get: { item.isOpen }, set: { _ in actions.open(item.id) })
                    )
                    .help(item.path)
                }
                Divider()
            }
            // Same action as File › Add Repository… (RepositoryCommands); whichever sees ⌘O first handles it.
            Button("Add Repository…", action: actions.add)
                .keyboardShortcut("o", modifiers: .command)
                .disabled(isAdding)
            if let removeTitle = model.removeTitle, let id = repository?.repository.id {
                Button(removeTitle) { actions.remove(id) }
            }
            Divider()
            Button("Manage Repositories…", action: actions.manage)
        } label: {
            HStack(spacing: Tokens.Spacing.xs) {
                Image(systemName: "folder")
                Text(repository?.name ?? String(localized: "No Repository")).font(Tokens.Font.bodyEmphasized)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(
            repository.map { repository in
                repository.owner.map { String(localized: "Repository \(repository.name) by \($0)") }
                    ?? String(localized: "Repository \(repository.name)")
            } ?? String(localized: "No repository"))
    }
}

/// The registered repositories in a sheet: each one's folder, with Remove, and Add Repository… (screens.md S-01).
struct ManageRepositoriesView: View {
    let model: RepositoryMenuModel
    let isAdding: Bool
    let actions: RepositoryActions
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            Text("Repositories").font(Tokens.Font.headline).foregroundStyle(Tokens.Color.textPrimary)
            if model.items.isEmpty {
                Text("No repositories yet. Add a Git repository or one of its worktrees.")
                    .font(Tokens.Font.body)
                    .foregroundStyle(Tokens.Color.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: Self.listHeight / 2)
            } else {
                List(model.items) { item in
                    HStack(spacing: Tokens.Spacing.sm) {
                        VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                            Text(item.name).font(Tokens.Font.bodyEmphasized)
                            Text(item.path)
                                .font(Tokens.Font.caption)
                                .foregroundStyle(Tokens.Color.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button("Remove") { actions.remove(item.id) }
                            .help("Remove “\(item.name)” from Overgrove. The folder is not changed.")
                    }
                    .accessibilityElement(children: .combine)
                }
                .frame(height: Self.listHeight)
            }
            Text("Removing a repository only takes it out of Overgrove. Its folder is not changed.")
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Color.textTertiary)
            HStack {
                Button("Add Repository…", action: actions.add).disabled(isAdding)
                Spacer()
                Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Tokens.Spacing.xl)
        .frame(width: Self.width)
    }

    /// No size tokens for sheets; a list of about six rows.
    static let width: CGFloat = 520
    static let listHeight: CGFloat = 240
}

/// The folder picker for Add Repository… (overview.md §9): one existing folder the user picks. Overgrove never
/// looks for repositories on its own.
@MainActor
enum RepositoryPicker {
    static func makePanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        // A Finder alias is returned as itself instead of silently swapped for its target, so registration sees
        // the picked path and warns about the difference (SEC-T14-01).
        panel.resolvesAliases = false
        panel.prompt = String(localized: "Add", comment: "The open panel's button that adds a repository")
        panel.message = String(localized: "Choose a Git repository or one of its worktrees.")
        return panel
    }

    /// Shows the picker as a sheet on `window` (app-modal without one). `nil` if cancelled.
    static func choose(in window: NSWindow?) async -> URL? {
        let panel = makePanel()
        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.url : nil
    }
}

// MARK: - File menu

private struct RepositoryActionsKey: FocusedValueKey {
    typealias Value = FocusedRepositoryActions
}

/// The focused window's Add Repository… (File menu) and Refresh (View menu).
struct FocusedRepositoryActions: Equatable {
    let isAdding: Bool
    let add: @MainActor () -> Void
    /// Whether a repository is open, so Refresh has something to do.
    var canRefresh = false
    var refresh: @MainActor () -> Void = {}
    /// Fetch `⌘⇧R` and Stop `⌘.` (Repository menu, #77).
    var canFetch = false
    var isFetching = false
    var fetch: @MainActor () -> Void = {}
    var stopFetch: @MainActor () -> Void = {}
    /// Help › Setup Assistant… (S-07, #85).
    var openSetup: @MainActor () -> Void = {}

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isAdding == rhs.isAdding && lhs.canRefresh == rhs.canRefresh && lhs.canFetch == rhs.canFetch
            && lhs.isFetching == rhs.isFetching
    }
}

extension FocusedValues {
    var repositoryActions: FocusedRepositoryActions? {
        get { self[RepositoryActionsKey.self] }
        set { self[RepositoryActionsKey.self] = newValue }
    }
}

/// File › Add Repository… `⌘O` (interaction.md §3, the standard Open shortcut), View › Refresh `⌘R` (local git
/// queries only, no network; #243), and Repository › Fetch `⌘⇧R` / Stop `⌘.` (#77).
struct RepositoryCommands: Commands {
    @FocusedValue(\.repositoryActions) private var actions

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Repository…") { actions?.add() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(actions == nil || actions?.isAdding == true)
        }
        CommandGroup(before: .sidebar) {
            Button("Refresh") { actions?.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(actions?.canRefresh != true)
            Divider()
        }
        // Help › Setup Assistant… (screens.md S-07).
        CommandGroup(after: .help) {
            Button("Setup Assistant…") { actions?.openSetup() }
                .disabled(actions == nil)
        }
        // Repository › Fetch `⌘⇧R` and Stop `⌘.` (interaction.md §3.1). Fetch is the app's only network command.
        CommandMenu("Repository") {
            Button("Fetch") { actions?.fetch() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(actions?.canFetch != true || actions?.isFetching == true)
            Button("Stop") { actions?.stopFetch() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(actions?.isFetching != true)
        }
    }
}
