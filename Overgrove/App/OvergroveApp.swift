import SwiftUI

/// Application entry point. Each main window (S-01) shows one repository and owns its `AppState`; only the panel
/// layout store, which keys layouts by repository, and the registered repositories are shared (prd.md,
/// interaction.md §1.1: one repository per window).
@main
struct OvergroveApp: App {
    private let layoutStore = PanelLayoutStore()
    private let registry = RepositoryRegistry()

    var body: some Scene {
        WindowGroup("Overgrove") {
            MainWindowScene(layoutStore: layoutStore, registry: registry)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            // View › Show/Hide Sidebar (⌃⌘S) and Show/Hide Detail (⌥⌘0) for the panel split container (#174).
            PanelCommands()
            // File › Add Repository… (⌘O) (#84).
            RepositoryCommands()
        }
    }
}

/// One window's root: creates that window's state once and keeps it for the window's lifetime.
struct MainWindowScene: View {
    @State private var state: AppState

    init(layoutStore: PanelLayoutStore, registry: RepositoryRegistry) {
        _state = State(initialValue: AppState(layoutStore: layoutStore, registry: registry))
    }

    var body: some View {
        MainWindowView(state: state)
    }
}
