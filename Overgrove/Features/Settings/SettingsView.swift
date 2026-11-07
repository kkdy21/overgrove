import SwiftUI

/// S-08, the standard Settings window (`⌘,`). Native controls in a grouped `Form`, so it follows system colors
/// (ADR-0014). There is no field for tokens or secrets.
///
/// General: auto fetch (shown once the scheduler exists, #79) and remote URL display. Repositories: the registered
/// list with Remove and Add…. Advanced (git executable, verbose logging) and the untracked toggle are later (#86).
struct SettingsView: View {
    @Bindable var settings: AppSettings
    let registry: RepositoryRegistry
    let actions: RepositoryListActions

    var body: some View {
        TabView {
            GeneralSettingsView(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            RepositoriesSettingsView(registry: registry, actions: actions)
                .tabItem { Label("Repositories", systemImage: "folder") }
        }
        .frame(width: Self.width)
    }

    /// No size token for the Settings window; the S-08 mockup's width.
    static let width: CGFloat = 520
}

private struct GeneralSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            if AppSettings.isAutoFetchAvailable {
                Section {
                    Toggle("Fetch automatically", isOn: $settings.autoFetch)
                    Picker("Every", selection: $settings.autoFetchIntervalMinutes) {
                        ForEach(AppSettings.autoFetchIntervals, id: \.self) { Text("\($0) min").tag($0) }
                    }
                    .disabled(!settings.autoFetch)
                } header: {
                    Text("Fetch")
                } footer: {
                    Text("Off by default. Uses your git credentials.")
                }
            }
            Section {
                Toggle("Show full remote URLs", isOn: $settings.showsFullRemoteURLs)
            } header: {
                Text("Remote URLs")
            } footer: {
                Text("Credentials in URLs are always masked. When off, only the host and path are shown.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct RepositoriesSettingsView: View {
    let registry: RepositoryRegistry
    let actions: RepositoryListActions
    @State private var isAdding = false
    @State private var message: SettingsMessage?

    var body: some View {
        Form {
            Section {
                if registry.repositories.isEmpty {
                    Text("No repositories yet.").foregroundStyle(.secondary)
                }
                ForEach(registry.repositories) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.name)
                            Text(entry.displayRootPath).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        // #107: the same flag as S-05's "Treat as untrusted".
                        Toggle(
                            "Untrusted",
                            isOn: Binding(
                                get: { entry.isUntrusted }, set: { registry.setUntrusted($0, for: entry.id) })
                        )
                        .toggleStyle(.checkbox)
                        .help("Do not fetch remotes on this Mac, and ask before Open in Terminal.")
                        Button("Remove") { actions.remove(entry.id) }
                            .help("Remove from Overgrove. The folder is not touched.")
                    }
                }
            } footer: {
                HStack {
                    Button("Add…", action: add).disabled(isAdding)
                    Spacer()
                    Text("Only folders you add here are ever read.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .alert(item: $message) { message in
            Alert(title: Text(message.title), message: Text(message.text))
        }
    }

    private func add() {
        Task {
            guard let folder = await RepositoryPicker.choose(in: NSApp.keyWindow) else { return }
            isAdding = true
            defer { isAdding = false }
            message = SettingsMessage(await actions.add(folder))
        }
    }
}

/// The alert after Add…, if anything needs saying.
private struct SettingsMessage: Identifiable {
    let id = UUID()
    let title: String
    let text: String

    init?(_ outcome: RepositoryListActions.AddOutcome) {
        switch outcome {
        case .added(let notice):
            guard let notice else { return nil }
            (title, text) = ("Repository Added", notice)
        case .alreadyRegistered(let name, let path):
            (title, text) = ("Repository Already Added", "“\(name)” is already in Overgrove, at \(path).")
        case .failed(let reason):
            (title, text) = ("Couldn’t Add Repository", reason)
        case .cancelled:
            return nil
        }
    }
}
