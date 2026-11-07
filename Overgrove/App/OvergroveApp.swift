import SwiftUI

/// Application entry point.
///
/// Phase 3 builds the real window (S-01) on top of the security foundation first; until then the app shows a
/// placeholder so the project builds, launches, and hosts the test bundle.
@main
struct OvergroveApp: App {
    var body: some Scene {
        WindowGroup("Overgrove") {
            PlaceholderView()
        }
        .commands {
            // View › Show/Hide Sidebar (⌃⌘S) and Show/Hide Detail (⌥⌘0) for the panel split container (#174).
            PanelCommands()
        }
    }
}
