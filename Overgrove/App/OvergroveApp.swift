import SwiftUI

/// Application entry point: one main window (S-01) over the app-level `AppState`.
@main
struct OvergroveApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("Overgrove") {
            MainWindowView(state: state)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            // View › Show/Hide Sidebar (⌃⌘S) and Show/Hide Detail (⌥⌘0) for the panel split container (#174).
            PanelCommands()
        }
    }
}
