import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Advanced › Apps (screens.md S-08, #124): the terminal for Open in Terminal and the editor for Open in
/// Editor. Only the app's bundle identifier is stored; Overgrove hands the app one folder or file with `NSWorkspace`
/// and builds no command line.
struct ExternalAppsSection: View {
    let settings: AppSettings
    /// The installed app for a bundle identifier (Settings and tests).
    var locate: @MainActor (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }

    @State private var error: String?
    @State private var details: [String: ExternalAppInfo] = [:]

    var body: some View {
        Section {
            row(.terminal, identifier: settings.terminalApp, defaultText: "Terminal (default)")
            row(.editor, identifier: settings.editorApp, defaultText: "None")
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Tokens.Color.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Apps")
        } footer: {
            Text(
                "Opened with macOS: Overgrove passes the worktree folder or file and nothing else. A folder whose "
                    + "settings can run commands asks first."
            )
            .foregroundStyle(.secondary)
        }
        .task(id: [settings.terminalApp, settings.editorApp]) { await loadDetails() }
    }

    @ViewBuilder
    private func row(_ role: ExternalAppRole, identifier: String?, defaultText: String) -> some View {
        LabeledContent(role.title) {
            VStack(alignment: .trailing, spacing: Tokens.Spacing.xxs) {
                Text(identifier.map { details[$0]?.name ?? $0 } ?? defaultText).lineLimit(1)
                if let identifier {
                    Text(Self.summary(identifier, details[identifier], isInstalled: locate(identifier) != nil))
                        .font(Tokens.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Choose…") { choose(role) }
                    Button(role == .terminal ? "Use Default" : "Clear") { set(nil, for: role) }
                        .disabled(identifier == nil)
                }
                .controlSize(.small)
            }
        }
    }

    /// `com.example.Editor · Apple-signed`, or that it is not installed (a plain String, so nothing is localized).
    static func summary(_ identifier: String, _ info: ExternalAppInfo?, isInstalled: Bool) -> String {
        guard isInstalled else { return "\(identifier) · not installed" }
        guard let info else { return identifier }
        return "\(identifier) · " + (info.isAppleSigned ? "Apple-signed" : "Not signed by Apple")
    }

    private func set(_ identifier: String?, for role: ExternalAppRole) {
        error = nil
        switch role {
        case .terminal: settings.terminalApp = identifier
        case .editor: settings.editorApp = identifier
        }
    }

    private func choose(_ role: ExternalAppRole) {
        Task {
            guard let url = await ExternalAppPicker.choose(role, in: NSApp.keyWindow) else { return }
            switch ExternalApps.inspect(url) {
            case .success(let info):
                details[info.bundleIdentifier] = info
                set(info.bundleIdentifier, for: role)
            case .failure(let refusal):
                error = refusal.message
            }
        }
    }

    /// Names and signatures of the chosen apps, checked off the main actor (a large bundle takes a moment).
    private func loadDetails() async {
        for identifier in [settings.terminalApp, settings.editorApp].compactMap({ $0 }) where details[identifier] == nil
        {
            guard let url = locate(identifier) else { continue }
            let info = await Task.detached { try? ExternalApps.inspect(url).get() }.value
            if let info, info.bundleIdentifier == identifier { details[identifier] = info }
        }
    }
}

/// The app picker for Choose…: one application, starting in /Applications.
@MainActor
enum ExternalAppPicker {
    static func choose(_ role: ExternalAppRole, in window: NSWindow?) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Use"
        panel.message = "Choose the \(role.title.lowercased()) to open worktrees in."
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
