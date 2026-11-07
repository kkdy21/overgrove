import SwiftUI

/// Application entry point. Each main window (S-01) shows one repository and owns its `AppState`; only the panel
/// layout store, which keys layouts by repository, the registered repositories, and the settings are shared (prd.md,
/// interaction.md §1.1: one repository per window).
@main
struct OvergroveApp: App {
    private let layoutStore = PanelLayoutStore()
    private let registry = RepositoryRegistry()
    private let settings = AppSettings()

    var body: some Scene {
        WindowGroup("Overgrove") {
            MainWindowScene(layoutStore: layoutStore, registry: registry, settings: settings)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            // View › Show/Hide Sidebar (⌃⌘S) and Show/Hide Detail (⌥⌘0) for the panel split container (#174).
            PanelCommands()
            // File › Add Repository… (⌘O) (#84).
            RepositoryCommands()
            NavigationCommands()
            // Edit › Find ⌘F, Find Next ⌘G, Find Previous ⌘⇧G, Filter Sidebar ⌥⌘F (#74).
            SearchCommands()
        }
        // S-08 (⌘,), #86.
        Settings {
            SettingsView(
                settings: settings, registry: registry,
                actions: RepositoryListActions(
                    registry: registry, registrar: .live, fetchRecords: FetchRecordStore(),
                    loader: LiveRepositoryLoader.live))
        }
    }
}

/// One window's root: creates that window's state once and keeps it for the window's lifetime.
struct MainWindowScene: View {
    @State private var state: AppState

    init(layoutStore: PanelLayoutStore, registry: RepositoryRegistry, settings: AppSettings) {
        _state = State(initialValue: AppState(layoutStore: layoutStore, registry: registry, settings: settings))
    }

    var body: some View {
        MainWindowView(state: state)
    }
}
