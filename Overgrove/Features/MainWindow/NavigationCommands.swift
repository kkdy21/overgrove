import SwiftUI

/// The window's navigation actions for the menu bar (interaction.md §3.1, #73).
struct FocusedNavigationActions: Equatable {
    var canJumpToHead = false
    var jumpToHead: @MainActor () -> Void = {}
    var canToggleWorktreeInfo = false
    var toggleWorktreeInfo: @MainActor () -> Void = {}
    var focus: @MainActor (PanelFocus) -> Void = { _ in }
    var fullPath: String?
    var copy: @MainActor (String) -> Void = { _ in }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.canJumpToHead == rhs.canJumpToHead && lhs.canToggleWorktreeInfo == rhs.canToggleWorktreeInfo
            && lhs.fullPath == rhs.fullPath
    }
}

private struct NavigationActionsKey: FocusedValueKey {
    typealias Value = FocusedNavigationActions
}

extension FocusedValues {
    var navigationActions: FocusedNavigationActions? {
        get { self[NavigationActionsKey.self] }
        set { self[NavigationActionsKey.self] = newValue }
    }
}

/// Navigate › Jump to HEAD `⌘J`, Show Worktree Info `⌘I`, Focus `⌘1`–`⌘4`; Edit › Copy Full Path `⌥⌘C`.
/// `⌘F` and `⌘G` belong to search (#74).
struct NavigationCommands: Commands {
    @FocusedValue(\.navigationActions) private var actions

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Copy Full Path") { if let path = actions?.fullPath { actions?.copy(path) } }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(actions?.fullPath == nil)
        }
        CommandMenu("Navigate") {
            Button("Jump to HEAD") { actions?.jumpToHead() }
                .keyboardShortcut("j", modifiers: .command)
                .disabled(actions?.canJumpToHead != true)
            Button("Show Worktree Info") { actions?.toggleWorktreeInfo() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(actions?.canToggleWorktreeInfo != true)
            Divider()
            Button("Focus Sidebar") { actions?.focus(.sidebar) }.keyboardShortcut("1", modifiers: .command)
            Button("Focus Graph") { actions?.focus(.center) }.keyboardShortcut("2", modifiers: .command)
            Button("Focus Detail") { actions?.focus(.detail) }.keyboardShortcut("3", modifiers: .command)
            Button("Focus Issues") { actions?.focus(.issues) }.keyboardShortcut("4", modifiers: .command)
        }
    }
}

private struct PanelFocusRequestKey: EnvironmentKey {
    static let defaultValue: PanelFocusRequest? = nil
}

extension EnvironmentValues {
    /// The latest `⌘1`–`⌘4` request (interaction.md §1.2).
    var panelFocusRequest: PanelFocusRequest? {
        get { self[PanelFocusRequestKey.self] }
        set { self[PanelFocusRequestKey.self] = newValue }
    }
}

extension View {
    /// Takes keyboard focus when `⌘1`–`⌘4` asks for one of `panels`.
    func focusOnRequest(_ panels: Set<PanelFocus>, _ isFocused: FocusState<Bool>.Binding) -> some View {
        modifier(PanelFocusTarget(panels: panels, isFocused: isFocused))
    }
}

private struct PanelFocusTarget: ViewModifier {
    let panels: Set<PanelFocus>
    let isFocused: FocusState<Bool>.Binding

    @Environment(\.panelFocusRequest) private var request

    func body(content: Content) -> some View {
        content.onChange(of: request) { _, request in
            if let request, panels.contains(request.panel) { isFocused.wrappedValue = true }
        }
    }
}
