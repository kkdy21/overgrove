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
