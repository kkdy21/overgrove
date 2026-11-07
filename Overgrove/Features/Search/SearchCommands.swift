import AppKit
import SwiftUI

/// The window's search actions for the menu bar (#74).
struct FocusedSearchActions: Equatable {
    var canFindMatch = false
    var findNext: @MainActor () -> Void = {}
    var findPrevious: @MainActor () -> Void = {}
    var filterSidebar: @MainActor () -> Void = {}

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.canFindMatch == rhs.canFindMatch }
}

private struct SearchActionsKey: FocusedValueKey {
    typealias Value = FocusedSearchActions
}

extension FocusedValues {
    var searchActions: FocusedSearchActions? {
        get { self[SearchActionsKey.self] }
        set { self[SearchActionsKey.self] = newValue }
    }
}

/// Edit › Find (interaction.md §3.1): Find `⌘F` (the toolbar search), Find Next `⌘G`, Find Previous `⌘⇧G`, and
/// Filter Sidebar `⌥⌘F`. They replace the text-editing Find group: the app has no editable text but these fields.
struct SearchCommands: Commands {
    @FocusedValue(\.searchActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .textEditing) {
            Button("Find…") { ToolbarSearch.focus() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions == nil)
            Button("Find Next") { actions?.findNext() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(actions?.canFindMatch != true)
            Button("Find Previous") { actions?.findPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(actions?.canFindMatch != true)
            Divider()
            Button("Filter Sidebar") { actions?.filterSidebar() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(actions == nil)
        }
    }
}

/// Focuses the window's toolbar search field. `searchFocused` needs macOS 15 and the app supports 14, so this goes
/// through AppKit on both: SwiftUI's toolbar `.searchable` is an `NSSearchToolbarItem`.
@MainActor
enum ToolbarSearch {
    static func focus(in window: NSWindow? = NSApp.keyWindow) {
        guard let window, let items = window.toolbar?.items else { return }
        if let item = items.lazy.compactMap({ $0 as? NSSearchToolbarItem }).first {
            item.beginSearchInteraction()
        } else if let field = items.lazy.compactMap({ $0.view as? NSSearchField }).first {
            window.makeFirstResponder(field)
        }
    }
}
