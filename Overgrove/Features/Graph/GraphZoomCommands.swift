import AppKit
import SwiftUI

/// View › Zoom In `⌘+`, Zoom Out `⌘−`, Actual Size `⌘0` (interaction.md §6.3, #121): the graph panel of every window.
struct GraphZoomCommands: Commands {
    let settings: AppSettings

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Zoom In") { settings.zoomGraphIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!settings.graphZoom.canZoomIn)
            Button("Zoom Out") { settings.zoomGraphOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!settings.graphZoom.canZoomOut)
            Button("Actual Size") { settings.resetGraphZoom() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(settings.graphZoom.isActualSize)
        }
    }
}

/// ⌘= for Zoom In (#478). The menu item's key is `+`, which on a US keyboard needs Shift; macOS does not match ⌘= to it
/// (measured with `NSMenu.performKeyEquivalent`), and a second visible menu item would show Zoom In twice. So the app
/// watches its own key events for ⌘= alone and zooms in as the menu does. Nothing else is taken.
@MainActor
enum GraphZoomShortcut {
    private static var monitor: Any?

    /// Installs the app's key monitor once. It sees only Overgrove's own events (`addLocalMonitorForEvents`).
    static func install(settings: AppSettings) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Key events arrive on the main thread; only the answer crosses into the main actor.
            guard isZoomIn(event) else { return event }
            return MainActor.assumeIsolated { zoomIn(settings) } ? nil : event
        }
    }

    /// Zooms in for ⌘= when the graph can still zoom in, and consumes the event; any other event is returned as is.
    static func handle(_ event: NSEvent, settings: AppSettings) -> NSEvent? {
        guard isZoomIn(event), zoomIn(settings) else { return event }
        return nil
    }

    /// Zoom In as the menu item does; `false` at the largest step (the menu item is disabled there).
    private static func zoomIn(_ settings: AppSettings) -> Bool {
        guard settings.graphZoom.canZoomIn else { return false }
        settings.zoomGraphIn()
        return true
    }

    /// A key-down of `=` with Command and no Shift, Option, or Control (Caps Lock and the keypad do not matter).
    nonisolated static func isZoomIn(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.charactersIgnoringModifiers == "=" else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        return modifiers == .command
    }
}
