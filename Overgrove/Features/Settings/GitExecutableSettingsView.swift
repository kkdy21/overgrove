import AppKit
import SwiftUI

/// Settings › Advanced (screens.md S-08): the git executable (ADR-0019, #106).
///
/// Shows the git in use with its real path, version, and whether Apple signed it, plus a note when it is too old to
/// fetch partial clones. Choose… saves a git only after it passes the rules; Use Default forgets the choice.
struct AdvancedSettingsView: View {
    @State var model: GitExecutableSettingsModel

    var body: some View {
        Form {
            Section {
                LabeledContent("git executable") {
                    Text(chosenText).font(Tokens.Font.mono).lineLimit(1).truncationMode(.middle)
                }
                status
                if let error = model.choiceError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Tokens.Color.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("git")
            } footer: {
                HStack {
                    Button("Choose…", action: choose).disabled(model.isWorking)
                    Button("Use Default") { Task { await model.useDefault() } }
                        .disabled(model.isWorking || model.isDefault)
                    Spacer()
                    Text("Must be an absolute path. Checked when chosen and every time Overgrove starts.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.refresh() }
    }

    private var chosenText: String {
        switch model.state {
        case .ready(let report): report.entered.map(PathValidator.displayable) ?? "Default (Xcode developer tools)"
        case .rejected(let path, _): path
        case .checking, .failed: model.isDefault ? "Default (Xcode developer tools)" : "Chosen git"
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.state {
        case .checking:
            ProgressView().controlSize(.small)
        case .ready(let report):
            VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                Text("Runs \(PathValidator.displayable(report.resolvedPath))")
                    .font(Tokens.Font.monoSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Self.summary(report)).foregroundStyle(.secondary)
                if report.hasOlderGitLimits {
                    Label(OlderGitNote.text, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        case .rejected(_, let reason):
            Label(
                "Cannot be used: \(reason) Queries are stopped until you choose another git or use the default.",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(Tokens.Color.statusWarning)
            .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(Tokens.Color.statusWarning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// `git 2.54.0 · Apple-signed` (a plain String, so the version is not localized).
    static func summary(_ report: GitExecutableReport) -> String {
        "git \(report.version) · " + (report.isAppleSigned ? "Apple-signed" : "Not signed by Apple")
    }

    private func choose() {
        Task {
            guard let file = await GitExecutablePicker.choose(in: NSApp.keyWindow) else { return }
            await model.choose(path: file.path)
        }
    }
}

/// The file picker for Choose… (ADR-0019 §1): one file, packages browsable so a git inside `Xcode.app` can be picked.
@MainActor
enum GitExecutablePicker {
    static func makePanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        // A Finder alias is returned as itself; the rules resolve links and show the real path.
        panel.resolvesAliases = false
        panel.prompt = "Use"
        panel.message = "Choose a git executable, for example /opt/homebrew/bin/git."
        return panel
    }

    /// Shows the picker as a sheet on `window` (app-modal without one). `nil` if cancelled.
    static func choose(in window: NSWindow?) async -> URL? {
        let panel = makePanel()
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
